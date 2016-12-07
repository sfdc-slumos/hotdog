#!/usr/bin/env ruby

require "fileutils"
require "dogapi"
require "multi_json"
require "oj"
require "open-uri"
require "parallel"
require "sqlite3"
require "uri"

module Hotdog
  module Commands
    class BaseCommand
      PERSISTENT_DB = "persistent.db"
      MASK_DATABASE = 0xffff0000
      MASK_QUERY = 0x0000ffff

      def initialize(application)
        @application = application
        @logger = application.logger
        @options = application.options
        @dog = nil # lazy initialization
        @prepared_statements = {}
      end
      attr_reader :application
      attr_reader :logger
      attr_reader :options

      def run(args=[], options={})
        raise(NotImplementedError)
      end

      def execute(q, args=[])
        update_db
        execute_db(@db, q, args)
      end

      def fixed_string?()
        @options[:fixed_string]
      end

      def reload(options={})
        if @db
          close_db(@db)
          @db = nil
        end
        update_db(options)
      end

      def define_options(optparse, options={})
        # nop
      end

      def parse_options(optparse, args=[])
        optparse.parse(args)
      end

      private
      def default_option(options, key, default_value)
        if options.key?(key)
          options[key]
        else
          options[key] = default_value
        end
      end

      def prepare(db, query)
        k = (db.hash & MASK_DATABASE) | (query.hash & MASK_QUERY)
        @prepared_statements[k] ||= db.prepare(query)
      end

      def format(result, options={})
        @options[:formatter].format(result, @options.merge(options))
      end

      def glob?(s)
        s.index('*') or s.index('?') or s.index('[') or s.index(']')
      end

      def get_hosts(host_ids, tags=nil)
        tags ||= @options[:tags]
        update_db
        if host_ids.empty?
          [[], []]
        else
          if 0 < tags.length
            fields = tags.map { |tag|
              tag_name, _tag_value = split_tag(tag)
              tag_name
            }
            get_hosts_fields(host_ids, fields)
          else
            if @options[:listing]
              q1 = "SELECT DISTINCT tags.name FROM hosts_tags " \
                     "INNER JOIN tags ON hosts_tags.tag_id = tags.id " \
                       "WHERE hosts_tags.host_id IN (%s);"
              if @options[:primary_tag]
                fields = [
                  @options[:primary_tag],
                  "host",
                ] + host_ids.each_slice(SQLITE_LIMIT_COMPOUND_SELECT).flat_map { |host_ids|
                  execute(q1 % host_ids.map { "?" }.join(", "), host_ids).map { |row| row.first }.reject { |tag_name|
                    tag_name == @options[:primary_tag]
                  }
                }
                get_hosts_fields(host_ids, fields)
              else
                fields = [
                  "host",
                ] + host_ids.each_slice(SQLITE_LIMIT_COMPOUND_SELECT).flat_map { |host_ids|
                  execute(q1 % host_ids.map { "?" }.join(", "), host_ids).map { |row| row.first }
                }
                get_hosts_fields(host_ids, fields)
              end
            else
              if @options[:primary_tag]
                get_hosts_fields(host_ids, [@options[:primary_tag]])
              else
                get_hosts_fields(host_ids, ["host"])
              end
            end
          end
        end
      end

      def get_hosts_fields(host_ids, fields)
        case fields.length
        when 0
          [[], fields]
        when 1
          get_hosts_field(host_ids, fields.first)
        else
          field_values = {}
          if fields.find { |field| /\Ahost\z/i =~ field }
            field_values = Hash[host_ids.each_slice(SQLITE_LIMIT_COMPOUND_SELECT).flat_map { |host_ids|
              execute("SELECT id, name FROM hosts WHERE id IN (%s)" % host_ids.map { "?" }.join(", "), host_ids).map { |row| 
                [row[0], {"host" => row[1]}]
              }
            }]
          else
            field_values = host_ids.map { Hash.new }
          end

          host_ids.each do |host_id|
            fields.reject { |field| /\Ahost\z/i =~ field }.uniq.each_slice(SQLITE_LIMIT_COMPOUND_SELECT - 1).each do |fields|
              q = "SELECT LOWER(tags.name), GROUP_CONCAT(tags.value, ',') FROM hosts_tags " \
                    "INNER JOIN tags ON hosts_tags.tag_id = tags.id " \
                      "WHERE hosts_tags.host_id = ? AND tags.name IN (%s) " \
                        "GROUP BY tags.name;" % fields.map { "?" }.join(", ")
              execute(q, [host_id] + fields).each do |row|
                (field_values[host_id] ||= {})[row[0]] = row[1]
              end
            end
          end

          result = host_ids.map { |host_id|
            fields.map { |tag_name|
              tag_value = field_values.fetch(host_id, {}).fetch(tag_name.downcase, nil)
              display_tag(tag_name, tag_value)
            }
          }
          [result, fields]
        end
      end

      def get_hosts_field(host_ids, field)
        if /\Ahost\z/i =~ field
          result = host_ids.each_slice(SQLITE_LIMIT_COMPOUND_SELECT).flat_map { |host_ids|
            execute("SELECT name FROM hosts WHERE id IN (%s)" % host_ids.map { "?" }.join(", "), host_ids).map { |row| row.to_a }
          }
        else
          result = host_ids.each_slice(SQLITE_LIMIT_COMPOUND_SELECT - 1).flat_map { |host_ids|
            q = "SELECT LOWER(tags.name), GROUP_CONCAT(tags.value, ',') FROM hosts_tags " \
                  "INNER JOIN tags ON hosts_tags.tag_id = tags.id " \
                    "WHERE hosts_tags.host_id IN (%s) AND tags.name = ? " \
                      "GROUP BY hosts_tags.host_id, tags.name;" % host_ids.map { "?" }.join(", ")
            r = execute(q, host_ids + [field]).map { |tag_name, tag_value|
              [display_tag(tag_name, tag_value)]
            }
            if r.empty?
              host_ids.map { [nil] }
            else
              r
            end
          }
        end
        [result, [field]]
      end

      def display_tag(tag_name, tag_value)
        if tag_value
          if tag_value.empty?
            tag_name # use `tag_name` as `tag_value` for the tags without any values
          else
            tag_value
          end
        else
          nil
        end
      end

      def close_db(db, options={})
        @prepared_statements = @prepared_statements.reject { |k, statement|
          (db.hash & MASK_DATABASE == k & MASK_DATABASE).tap do |delete_p|
            statement.close() if delete_p
          end
        }
        db.close()
      end

      def open_db(options={})
        options = @options.merge(options)
        if @db
          @db
        else
          FileUtils.mkdir_p(options[:confdir])
          persistent = File.join(options[:confdir], PERSISTENT_DB)

          if (not options[:force] and File.exist?(persistent) and Time.new < File.mtime(persistent) + options[:expiry]) or options[:offline]
            begin
              persistent_db = SQLite3::Database.new(persistent)
              persistent_db.execute("SELECT hosts_tags.host_id FROM hosts_tags INNER JOIN hosts ON hosts_tags.host_id = hosts.id INNER JOIN tags ON hosts_tags.tag_id = tags.id LIMIT 1;")
              @db = persistent_db
            rescue SQLite3::SQLException
              if options[:offline]
                raise(RuntimeError.new("no database available on offline mode"))
              else
                persistent_db.close()
              end
            end
          end
          @db
        end
      end

      def update_db(options={})
        options = @options.merge(options)
        if open_db(options)
          @db
        else
          memory_db = SQLite3::Database.new(":memory:")
          execute_db(memory_db, "CREATE TABLE IF NOT EXISTS hosts (id INTEGER PRIMARY KEY AUTOINCREMENT, name VARCHAR(255) NOT NULL COLLATE NOCASE);")
          execute_db(memory_db, "CREATE UNIQUE INDEX IF NOT EXISTS hosts_name ON hosts (name);")
          execute_db(memory_db, "CREATE TABLE IF NOT EXISTS tags (id INTEGER PRIMARY KEY AUTOINCREMENT, name VARCHAR(200) NOT NULL COLLATE NOCASE, value VARCHAR(200) NOT NULL COLLATE NOCASE);")
          execute_db(memory_db, "CREATE UNIQUE INDEX IF NOT EXISTS tags_name_value ON tags (name, value);")
          execute_db(memory_db, "CREATE TABLE IF NOT EXISTS hosts_tags (host_id INTEGER NOT NULL, tag_id INTEGER NOT NULL);")
          execute_db(memory_db, "CREATE UNIQUE INDEX IF NOT EXISTS hosts_tags_host_id_tag_id ON hosts_tags (host_id, tag_id);")

          all_tags = get_all_tags()

          memory_db.transaction do
            known_tags = all_tags.keys.map { |tag| split_tag(tag) }.uniq
            create_tags(memory_db, known_tags)

            known_hosts = all_tags.values.reduce(:+).uniq
            create_hosts(memory_db, known_hosts)

            all_tags.each do |tag, hosts|
              associate_tag_hosts(memory_db, tag, hosts)
            end
          end

          # backup in-memory db to file
          FileUtils.mkdir_p(options[:confdir])
          persistent = File.join(options[:confdir], PERSISTENT_DB)
          FileUtils.rm_f(persistent)
          persistent_db = SQLite3::Database.new(persistent)
          copy_db(memory_db, persistent_db)
          close_db(memory_db)
          @db = persistent_db
        end
      end

      def execute_db(db, q, args=[])
        begin
          logger.debug("execute: #{q} -- #{args.inspect}")
          prepare(db, q).execute(args)
        rescue
          logger.warn("failed: #{q} -- #{args.inspect}")
          raise
        end
      end

      def get_all_tags() #==> Hash<Tag,Array<Host>>
        endpoint = options[:endpoint]
        requests = {all_downtime: "/api/v1/downtime", all_tags: "/api/v1/tags/hosts"}
        query = URI.encode_www_form(api_key: application.api_key, application_key: application.application_key)
        begin
          parallelism = Parallel.processor_count
          responses = Hash[Parallel.map(requests, in_threads: parallelism) { |name, request_path|
            uri = URI.join(endpoint, "#{request_path}?#{query}")
            begin
              response = uri.open("User-Agent" => "hotdog/#{Hotdog::VERSION}") { |fp| fp.read }
              [name, MultiJson.load(response)]
            rescue OpenURI::HTTPError => error
              code, _body = error.io.status
              raise(RuntimeError.new("dog.get_#{name}() returns [#{code.inspect}, ...]"))
            end
          }]
        rescue => error
          STDERR.puts(error.message)
          exit(1)
        end
        now = Time.new.to_i
        downtimes = responses.fetch(:all_downtime, []).select { |downtime|
          # active downtimes
          downtime["active"] and ( downtime["start"].nil? or downtime["start"] < now ) and ( downtime["end"].nil? or now <= downtime["end"] ) and downtime["monitor_id"].nil?
        }.flat_map { |downtime|
          # find host scopes
          downtime["scope"].select { |scope| scope.start_with?("host:") }.map { |scope| scope.sub(/\Ahost:/, "") }
        }
        if not downtimes.empty?
          logger.info("ignore host(s) with scheduled downtimes: #{downtimes.inspect}")
        end
        Hash[responses.fetch(:all_tags, {}).fetch("tags", []).map { |tag, hosts| [tag, hosts.reject { |host| downtimes.include?(host) }] }]
      end

      def create_hosts(db, hosts)
        hosts.each_slice(SQLITE_LIMIT_COMPOUND_SELECT) do |hosts|
          q = "INSERT OR IGNORE INTO hosts (name) VALUES %s" % hosts.map { "(?)" }.join(", ")
          execute_db(db, q, hosts)
        end
      end

      def create_tags(db, tags)
        tags.each_slice(SQLITE_LIMIT_COMPOUND_SELECT / 2) do |tags|
          q = "INSERT OR IGNORE INTO tags (name, value) VALUES %s" % tags.map { "(?, ?)" }.join(", ")
          execute_db(db, q, tags)
        end
      end

      def associate_tag_hosts(db, tag, hosts)
        hosts.each_slice(SQLITE_LIMIT_COMPOUND_SELECT - 2) do |hosts|
          q = "INSERT OR REPLACE INTO hosts_tags (host_id, tag_id) " \
                "SELECT host.id, tag.id FROM " \
                  "( SELECT id FROM hosts WHERE name IN (%s) ) AS host, " \
                  "( SELECT id FROM tags WHERE name = ? AND value = ? LIMIT 1 ) AS tag;" % hosts.map { "?" }.join(", ")
          begin
            execute_db(db, q, (hosts + split_tag(tag)))
          rescue SQLite3::RangeException => error
            # FIXME: bulk insert occationally fails even if there are no errors in bind parameters
            #        `bind_param': bind or column index out of range (SQLite3::RangeException)
            logger.warn("bulk insert failed due to #{error.message}. fallback to normal insert.")
            hosts.each do |host|
              q = "INSERT OR REPLACE INTO hosts_tags (host_id, tag_id) " \
                    "SELECT host.id, tag.id FROM " \
                      "( SELECT id FROM hosts WHERE name = ? ) AS host, " \
                      "( SELECT id FROM tags WHERE name = ? AND value = ? LIMIT 1 ) AS tag;"
              execute_db(db, q, [host] + split_tag(tag))
            end
          end
        end
      end

      def disassociate_tag_hosts(db, tag, hosts)
        hosts.each_slice(SQLITE_LIMIT_COMPOUND_SELECT - 2) do |hosts|
          q = "DELETE FROM hosts_tags " \
                "WHERE tag_id IN ( SELECT id FROM tags WHERE name = ? AND value = ? LIMIT 1 );" \
                  "AND host_id IN ( SELECT id FROM hosts WHERE name IN (%s) ) " % hosts.map { "?" }.join(", ")
          execute_db(db, q, split_tag(tag) + hosts)
        end
      end

      def dog()
        @dog ||= Dogapi::Client.new(application.api_key, application.application_key)
      end

      def split_tag(tag)
        tag_name, tag_value = tag.split(":", 2)
        [tag_name, tag_value || ""]
      end

      def join_tag(tag_name, tag_value)
        if tag_value.to_s.empty?
          tag_name
        else
          "#{tag_name}:#{tag_value}"
        end
      end

      def copy_db(src, dst)
        backup = SQLite3::Backup.new(dst, "main", src, "main")
        backup.step(-1)
        backup.finish
      end

      def with_retry(options={}, &block)
        (options[:retry] || 1).times do |i|
          begin
            return yield
          rescue => error
            logger.warn(error.to_s)
            sleep(options[:retry_delay] || (1<<i))
          end
        end
        raise("retry count exceeded")
      end
    end
  end
end

# vim:set ft=ruby :
