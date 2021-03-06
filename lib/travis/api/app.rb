require 'travis'
require 'travis/model'
require 'travis/support/amqp'
require 'travis/states_cache'
require 'backports'
require 'rack'
require 'rack/protection'
require 'rack/contrib'
require 'dalli'
require 'memcachier'
require 'rack/cache'
require 'rack/attack'
require 'active_record'
require 'redis'
require 'gh'
require 'raven'
require 'sidekiq'
require 'metriks/reporter/logger'
require 'metriks/librato_metrics_reporter'
require 'travis/support/log_subscriber/active_record_metrics'
require 'fileutils'
require 'travis/api/v2/http'

# Rack class implementing the HTTP API.
# Instances respond to #call.
#
#     run Travis::Api::App.new
#
# Requires TLS in production.
module Travis::Api
  class App
    autoload :AccessToken,  'travis/api/app/access_token'
    autoload :Base,         'travis/api/app/base'
    autoload :Endpoint,     'travis/api/app/endpoint'
    autoload :Extensions,   'travis/api/app/extensions'
    autoload :Helpers,      'travis/api/app/helpers'
    autoload :Middleware,   'travis/api/app/middleware'
    autoload :Responders,   'travis/api/app/responders'
    autoload :Cors,         'travis/api/app/cors'

    Rack.autoload :SSL, 'rack/ssl'

    ERROR_RESPONSE = JSON.generate(error: 'Travis encountered an error, sorry :(')

    # Used to track if setup already ran.
    def self.setup?
      @setup ||= false
    end

    # Loads all endpoints and middleware and hooks them up properly.
    # Calls #setup on any middleware and endpoint.
    #
    # This method is not threadsafe, but called when loading
    # the environment, so no biggy.
    def self.setup(options = {})
      setup! unless setup?
      Endpoint.set(options) if options
      FileUtils.touch('/tmp/app-initialized') if ENV['DYNO'] # Heroku
    end

    def self.new(options = {})
      setup(options)
      super()
    end

    def self.deploy_sha
      @deploy_sha ||= File.exist?(deploy_sha_path) ? File.read(deploy_sha_path)[0..7] : 'deploy-sha'
    end

    def self.deploy_sha_path
      File.expand_path('../../../../.deploy-sha', __FILE__)
    end

    attr_accessor :app

    def initialize
      @app = Rack::Builder.app do
        use(Rack::Config) { |env| env['metriks.request.start'] ||= Time.now.utc }

        Rack::Utils::HTTP_STATUS_CODES[420] = "Enhance Your Calm"
        use Rack::Attack
        Rack::Attack.blacklist('block client requesting ruby builds') do |req|
          req.ip == "130.15.4.210"
        end

        Rack::Attack.blacklisted_response = lambda do |env|
          [ 420, {}, ['Enhance Your Calm']]
        end

        use Travis::Api::App::Cors # if Travis.env == 'development' ???
        use Raven::Rack if Endpoint.production? && Travis.config.sentry.dsn
        use Rack::Protection::PathTraversal
        use Rack::SSL if Endpoint.production?
        use ActiveRecord::ConnectionAdapters::ConnectionManagement
        use ActiveRecord::QueryCache

        memcache_servers = ENV['MEMCACHIER_SERVERS']
        if Travis::Features.feature_active?(:use_rack_cache) && memcache_servers
          use Rack::Cache,
            metastore:   "memcached://#{memcache_servers}/meta-#{Travis::Api::App.deploy_sha}",
            entitystore: "memcached://#{memcache_servers}/body-#{Travis::Api::App.deploy_sha}"
        end

        use Rack::Deflater
        use Rack::PostBodyContentTypeParser
        use Rack::JSONP

        use Rack::Config do |env|
          env['SCRIPT_NAME'] = env['HTTP_X_SCRIPT_NAME'].to_s + env['SCRIPT_NAME'].to_s
          env['travis.global_prefix'] = env['SCRIPT_NAME']
        end

        use Travis::Api::App::Middleware::ScopeCheck
        use Travis::Api::App::Middleware::Logging
        use Travis::Api::App::Middleware::Metriks
        use Travis::Api::App::Middleware::Rewrite
        use Travis::Api::App::Middleware::UserAgentTracker

        SettingsEndpoint.subclass :env_vars
        if Travis.config.endpoints.ssh_key
          SingletonSettingsEndpoint.subclass :ssh_key
        end

        Endpoint.subclasses.each do |e|
          next if e == SettingsEndpoint # TODO: add something like abstract? method to check if
                                        # class should be registered
          map(e.prefix) { run(e.new) }
        end
      end
    end

    # Rack protocol
    def call(env)
      app.call(env)
    rescue
      if Endpoint.production?
        [500, {'Content-Type' => 'application/json'}, [ERROR_RESPONSE]]
      else
        raise
      end
    end

    private

      def self.console?
        defined? Travis::Console
      end

      def self.setup!
        setup_travis
        load_endpoints
        setup_endpoints
        @setup = true
      end

      def self.setup_travis
        Travis::Async.enabled = true
        Travis::Amqp.config = Travis.config.amqp

        setup_database_connections

        if Travis.env == 'production' || Travis.env == 'staging'
          Sidekiq.configure_client do |config|
            config.redis = Travis.config.redis.merge(size: 1, namespace: Travis.config.sidekiq.namespace)
          end
        end

        if (Travis.env == 'production' || Travis.env == 'staging') and not console?
          setup_monitoring
        end
      end

      def self.setup_database_connections
        Travis::Database.connect

        if Travis.config.logs_database
          Log.establish_connection 'logs_database'
          Log::Part.establish_connection 'logs_database'
        end
      end

      def self.setup_monitoring
        Raven.configure do |config|
          config.dsn = Travis.config.sentry.dsn
        end if Travis.config.sentry.dsn

        Travis::LogSubscriber::ActiveRecordMetrics.attach
        Travis::Notification.setup(instrumentation: false)
        Travis::Metrics.setup
      end

      def self.load_endpoints
        Backports.require_relative_dir 'app/middleware'
        Backports.require_relative_dir 'app/endpoint'
      end

      def self.setup_endpoints
        Base.subclasses.each(&:setup)
      end
  end
end
