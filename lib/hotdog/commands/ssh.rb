#!/usr/bin/env ruby

require "json"
require "parslet"
require "shellwords"
require "hotdog/commands/search"

module Hotdog
  module Commands
    class SshAlike < Search
      def define_options(optparse, options={})
        default_option(options, :options, [])
        default_option(options, :user, nil)
        default_option(options, :port, nil)
        default_option(options, :identity_file, nil)
        default_option(options, :forward_agent, false)
        default_option(options, :color, :auto)
        default_option(options, :max_parallelism, Parallel.processor_count)
        optparse.on("-o SSH_OPTION", "Passes this string to ssh command through shell. This option may be given multiple times") do |option|
          options[:options] += [option]
        end
        optparse.on("-i SSH_IDENTITY_FILE", "SSH identity file path") do |path|
          options[:identity_file] = path
        end
        optparse.on("-A", "Enable agent forwarding", TrueClass) do |b|
          options[:forward_agent] = b
        end
        optparse.on("-p PORT", "Port of the remote host", Integer) do |port|
          options[:port] = port
        end
        optparse.on("-u SSH_USER", "SSH login user name") do |user|
          options[:user] = user
        end
        optparse.on("-v", "--verbose", "Enable verbose ode") do |v|
          options[:verbose] = v
        end
        optparse.on("--filter=COMMAND", "Command to filter search result.") do |command|
          options[:filter_command] = command
        end
        optparse.on("-P PARALLELISM", "Max parallelism", Integer) do |n|
          options[:max_parallelism] = n
        end
        optparse.on("--color=WHEN", "--colour=WHEN", "Enable colors") do |color|
          options[:color] = color
        end
      end

      def run(args=[], options={})
        expression = args.join(" ").strip
        if expression.empty?
          # return everything if given expression is empty
          expression = "*"
        end

        begin
          node = parse(expression)
        rescue Parslet::ParseFailed => error
          STDERR.puts("syntax error: " + error.cause.ascii_tree)
          exit(1)
        end

        result0 = evaluate(node, self)
        result, _fields = get_hosts_with_search_tags(result0, node)
        hosts = filter_hosts(result.flatten)
        validate_hosts!(hosts)
        run_main(hosts, options)
      end

      private
      def parallelism(hosts)
        options[:max_parallelism] || hosts.size
      end

      def filter_hosts(hosts)
        if options[:filter_command]
          filtered_hosts = Parallel.map(hosts, in_threads: parallelism(hosts)) { |host|
            cmdline = build_command_string(host, options[:filter_command], options)
            [host, exec_command(host, cmdline, output: false)]
          }.select { |_host, stat|
            stat
          }.map { |host, _stat|
            host
          }
          if hosts == filtered_hosts
            hosts
          else
            logger.info("filtered host(s): #{(hosts - filtered_hosts).inspect}")
            filtered_hosts
          end
        else
          hosts
        end
      end

      def validate_hosts!(hosts)
        if hosts.length < 1
          STDERR.puts("no match found")
          exit(1)
        end
      end

      def run_main(hosts, options={})
        raise(NotImplementedError)
      end

      def build_command_options(options={})
        cmdline = []
        if options[:forward_agent]
          cmdline << "-A"
        end
        if options[:identity_file]
          cmdline << "-i" << options[:identity_file]
        end
        if options[:user]
          cmdline << "-l" << options[:user]
        end
        if options[:options]
          cmdline += options[:options].flat_map { |option| ["-o", option] }
        end
        if options[:port]
          cmdline << "-p" << options[:port].to_s
        end
        if options[:verbose]
          cmdline << "-v"
        end
        cmdline
      end

      def build_command_string(host, command=nil, options={})
        # build ssh command
        cmdline = ["ssh"] + build_command_options(options) + [host]
        if command
          cmdline << "--" << command
        end
        Shellwords.join(cmdline)
      end

      def use_color?
        case options[:color]
        when :always
          true
        when :never
          false
        else
          STDOUT.tty?
        end
      end

      def exec_command(identifier, cmdline, options={})
        output = options.fetch(:output, true)
        logger.debug("execute: #{cmdline}")
        if use_color?
          if options.key?(:index)
            color = 31 + (options[:index] % 6)
          else
            color = 36
          end
        else
          color = nil
        end
        if options[:infile]
          stdin = IO.popen("cat #{Shellwords.shellescape(options[:infile])}")
        else
          stdin = :close
        end
        IO.popen(cmdline, in: stdin) do |io|
          io.each_with_index do |s, i|
            if output
              if identifier
                if color
                  STDOUT.write("\e[0;#{color}m")
                end
                STDOUT.write(identifier)
                STDOUT.write(":")
                STDOUT.write(i.to_s)
                STDOUT.write(":")
                if color
                  STDOUT.write("\e[0m")
                end
              end
              STDOUT.puts(s)
            end
          end
        end
        $?.success? # $? is thread-local variable
      end
    end

    class SingularSshAlike < SshAlike
      def define_options(optparse, options={})
        super
        options[:index] = nil
        optparse.on("-n", "--index INDEX", "Use this index of host if multiple servers are found", Integer) do |index|
          options[:index] = index
        end
      end

      private
      def filter_hosts(hosts)
        hosts = super
        if options[:index] and options[:index] < hosts.length
          [hosts[options[:index]]]
        else
          hosts
        end
      end

      def validate_hosts!(hosts)
        super
        if hosts.length != 1
          result = hosts.each_with_index.map { |host, i| [i, host] }
          STDERR.print(format(result, fields: ["index", "host"]))
          logger.error("found %d candidates." % result.length)
          exit(1)
        end
      end

      def run_main(hosts, options={})
        cmdline = build_command_string(hosts.first, @remote_command, options)
        logger.debug("execute: #{cmdline}")
        exec(cmdline)
        exit(127)
      end
    end

    class Ssh < SingularSshAlike
      def define_options(optparse, options={})
        super
        optparse.on("-D BIND_ADDRESS", "Specifies a local \"dynamic\" application-level port forwarding") do |bind_address|
          options[:dynamic_port_forward] = bind_address
        end
        optparse.on("-L BIND_ADDRESS", "Specifies that the given port on the local (client) host is to be forwarded to the given host and port on the remote side") do |bind_address|
          options[:port_forward] = bind_address
        end
      end

      private
      def build_command_options(options={})
        arguments = super
        if options[:dynamic_port_forward]
          arguments << "-D" << options[:dynamic_port_forward]
        end
        if options[:port_forward]
          arguments << "-L" << options[:port_forward]
        end
        arguments
      end
    end
  end
end
