# encoding: utf-8
# author: Christoph Hartmann
# author: Dominik Richter

require 'thor'
require 'inspec/log'
require 'inspec/profile_vendor'

module Inspec
  class BaseCLI < Thor
    def self.target_options
      option :target, aliases: :t, type: :string,
        desc: 'Simple targeting option using URIs, e.g. ssh://user:pass@host:port'
      option :backend, aliases: :b, type: :string,
        desc: 'Choose a backend: local, ssh, winrm, docker.'
      option :host, type: :string,
        desc: 'Specify a remote host which is tested.'
      option :port, aliases: :p, type: :numeric,
        desc: 'Specify the login port for a remote scan.'
      option :user, type: :string,
        desc: 'The login user for a remote scan.'
      option :password, type: :string, lazy_default: -1,
        desc: 'Login password for a remote scan, if required.'
      option :key_files, aliases: :i, type: :array,
        desc: 'Login key or certificate file for a remote scan.'
      option :path, type: :string,
        desc: 'Login path to use when connecting to the target (WinRM).'
      option :sudo, type: :boolean,
        desc: 'Run scans with sudo. Only activates on Unix and non-root user.'
      option :sudo_password, type: :string, lazy_default: -1,
        desc: 'Specify a sudo password, if it is required.'
      option :sudo_options, type: :string,
        desc: 'Additional sudo options for a remote scan.'
      option :sudo_command, type: :string,
        desc: 'Alternate command for sudo.'
      option :shell, type: :boolean,
        desc: 'Run scans in a subshell. Only activates on Unix.'
      option :shell_options, type: :string,
        desc: 'Additional shell options.'
      option :shell_command, type: :string,
        desc: 'Specify a particular shell to use.'
      option :ssl, type: :boolean,
        desc: 'Use SSL for transport layer encryption (WinRM).'
      option :self_signed, type: :boolean,
        desc: 'Allow remote scans with self-signed certificates (WinRM).'
      option :json_config, type: :string,
        desc: 'Read configuration from JSON file (`-` reads from stdin).'
    end

    def self.profile_options
      option :profiles_path, type: :string,
        desc: 'Folder which contains referenced profiles.'
    end

    def self.exec_options
      target_options
      profile_options
      option :controls, type: :array,
        desc: 'A list of controls to run. Ignore all other tests.'
      # TODO: remove in inspec 2.0
      option :format, type: :string,
        desc: '[DEPRECATED] Please use --reporter - this will be removed in InSpec 3.0'
      option :reporter, type: :array,
        banner: 'one two:/output/file/path',
        desc: 'Enable one or more output reporters: cli, documentation, html, progress, json, json-min, json-rspec, junit'
      option :color, type: :boolean,
        desc: 'Use colors in output.'
      option :attrs, type: :array,
        desc: 'Load attributes file (experimental)'
      # TODO: remove in inspec 2.0
      option :cache, type: :string,
        desc: '[DEPRECATED] Please use --vendor-cache - this will be removed in InSpec 2.0'
      option :vendor_cache, type: :string,
        desc: 'Use the given path for caching dependencies. (default: ~/.inspec/cache)'
      option :create_lockfile, type: :boolean,
        desc: 'Write out a lockfile based on this execution (unless one already exists)'
      option :backend_cache, type: :boolean,
        desc: 'Allow caching for backend command output.'
      option :show_progress, type: :boolean,
        desc: 'Show progress while executing tests.'
    end

    def self.default_options
      {
        exec: {
          'reporter' => ['cli'],
          'show_progress' => false,
          'color' => true,
          'create_lockfile' => true,
          'backend_cache' => false,
        },
        shell: {
          'reporter' => ['cli'],
        },
      }
    end

    def self.parse_reporters(opts)
      # merge in any legacy formats as reporter
      # this method will only be used for ad-hoc runners
      if !opts['format'].nil? && opts['reporter'].nil?
        warn '[DEPRECATED] The option --format is being is being deprecated and will be removed in inspec 3.0. Please use --reporter'
        opts['reporter'] = Array(opts['format'])
        opts.delete('format')
      end

      # parse out cli to proper report format
      if opts['reporter'].is_a?(Array)
        reports = {}
        opts['reporter'].each do |report|
          reporter_name, target = report.split(':')
          if target.nil? || target.strip == '-'
            reports[reporter_name] = { 'stdout' => true }
          else
            reports[reporter_name] = {
              'file' => target,
              'stdout' => false,
            }
          end
        end
        opts['reporter'] = reports
      end

      # add in stdout if not specified
      if opts['reporter'].is_a?(Hash)
        opts['reporter'].each do |reporter_name, config|
          opts['reporter'][reporter_name] = {} if config.nil?
          opts['reporter'][reporter_name]['stdout'] = true if opts['reporter'][reporter_name].empty?
        end
      end

      validate_reporters(opts['reporter'])
      opts
    end

    def self.validate_reporters(reporters)
      return if reporters.nil?

      valid_types = [
        'json',
        'json-min',
        'json-rspec',
        'cli',
        'junit',
        'html',
        'documentation',
        'progress',
      ]

      reporters.each do |k, _v|
        raise NotImplementedError, "'#{k}' is not a valid reporter type." unless valid_types.include?(k)
      end

      # check to make sure we are only reporting one type to stdout
      stdout = 0
      reporters.each_value do |v|
        stdout += 1 if v['stdout'] == true
      end

      raise ArgumentError, 'The option --reporter can only have a single report outputting to stdout.' if stdout > 1
    end

    private

    def suppress_log_output?(opts)
      return false if opts['reporter'].nil?
      match = %w{json json-min json-rspec junit html} & opts['reporter'].keys
      unless match.empty?
        match.each do |m|
          # check to see if we are outputting to stdout
          return true if opts['reporter'][m]['stdout'] == true
        end
      end
      false
    end

    def diagnose(opts)
      return unless opts['diagnose']
      puts "InSpec version: #{Inspec::VERSION}"
      puts "Train version: #{Train::VERSION}"
      puts 'Command line configuration:'
      pp options
      puts 'JSON configuration file:'
      pp options_json
      puts 'Merged configuration:'
      pp opts
      puts
    end

    def opts(type = nil)
      o = merged_opts(type)

      # Due to limitations in Thor it is not possible to set an argument to be
      # both optional and its value to be mandatory. E.g. the user supplying
      # the --password argument is optional and not always required, but
      # whenever it is used, it requires a value. Handle options that were
      # defined above and require a value here:
      %w{password sudo-password}.each do |v|
        id = v.tr('-', '_').to_sym
        next unless o[id] == -1
        raise ArgumentError, "Please provide a value for --#{v}. For example: --#{v}=hello."
      end

      o
    end

    def merged_opts(type = nil)
      opts = {}
      opts[:type] = type unless type.nil?

      # start with default options if we have any
      opts = BaseCLI.default_options[type] unless type.nil? || BaseCLI.default_options[type].nil?

      # merge in any options from json-config
      opts.merge!(options_json)

      # remove the default reporter if we are setting a legacy format on the cli
      opts.delete('reporter') if options['format']

      # merge in any options defined via thor
      opts.merge!(options)

      # parse reporter options
      opts = BaseCLI.parse_reporters(opts) if %i(exec shell).include?(type)

      Thor::CoreExt::HashWithIndifferentAccess.new(opts)
    end

    def clean_reporters(opts)
      reports = {}
      stdout = 0
      unless opts['format'].nil?
        opts['reporter'] = []
        opts['reporter'] << opts['format']
        opts.delete('format')
      end
      return if opts['reporter'].nil?

      opts['reporter'].each do |report|
        k, v = report.split(':')
        reports[k] = v
        stdout += 1 if v.nil? || v == '-'
      end

      raise ArgumentError, 'The option --reporter can only have a single report outputting to stdout.' if stdout > 1

      opts['reporter'] = reports
    end

    def options_json
      conffile = options['json_config']
      @json ||= conffile ? read_config(conffile) : {}
    end

    def read_config(file)
      if file == '-'
        puts 'WARN: reading JSON config from standard input' if STDIN.tty?
        config = STDIN.read
      else
        config = File.read(file)
      end

      JSON.parse(config)
    rescue JSON::ParserError => e
      puts "Failed to load JSON configuration: #{e}\nConfig was: #{config.inspect}"
      exit 1
    end

    # get the log level
    # DEBUG < INFO < WARN < ERROR < FATAL < UNKNOWN
    def get_log_level(level)
      valid = %w{debug info warn error fatal}

      if valid.include?(level)
        l = level
      else
        l = 'info'
      end

      Logger.const_get(l.upcase)
    end

    def pretty_handle_exception(exception)
      case exception
      when Inspec::Error
        $stderr.puts exception.message
        exit(1)
      else
        raise exception
      end
    end

    def vendor_deps(path, opts)
      profile_path = path || Dir.pwd
      profile_vendor = Inspec::ProfileVendor.new(profile_path)

      if (profile_vendor.cache_path.exist? || profile_vendor.lockfile.exist?) && !opts[:overwrite]
        puts 'Profile is already vendored. Use --overwrite.'
        return false
      end

      profile_vendor.vendor!
      puts "Dependencies for profile #{profile_path} successfully vendored to #{profile_vendor.cache_path}"
    rescue StandardError => e
      pretty_handle_exception(e)
    end

    def configure_logger(o)
      #
      # TODO(ssd): This is a big gross, but this configures the
      # logging singleton Inspec::Log. Eventually it would be nice to
      # move internal debug logging to use this logging singleton.
      #
      loc = if o.log_location
              o.log_location
            elsif suppress_log_output?(o)
              STDERR
            else
              STDOUT
            end

      Inspec::Log.init(loc)
      Inspec::Log.level = get_log_level(o.log_level)

      o[:logger] = Logger.new(STDOUT)
      # output json if we have activated the json formatter
      if o['log-format'] == 'json'
        o[:logger].formatter = Logger::JSONFormatter.new
      end
      o[:logger].level = get_log_level(o.log_level)
    end

    def mark_text(text)
      "\e[0;36m#{text}\e[0m"
    end

    def headline(title)
      puts "\n== #{title}\n\n"
    end

    def li(entry)
      puts " #{mark_text('*')} #{entry}"
    end
  end
end
