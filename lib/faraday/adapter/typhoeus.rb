module Faraday
  class Adapter
    class Typhoeus < Faraday::Adapter
      self.supports_parallel = true

      def self.setup_parallel_manager(options = {})
        ::Typhoeus::Hydra.new(options)
      end

      dependency 'typhoeus'

      def call(env)
        super
        perform_request env
        @app.call env
      end

      def perform_request(env)
        read_body env

        hydra = env[:parallel_manager] || self.class.setup_parallel_manager
        hydra.queue request(env)
        hydra.run unless parallel?(env)
      rescue Errno::ECONNREFUSED
        raise Error::ConnectionFailed, $!
      end

      # TODO: support streaming requests
      def read_body(env)
        env[:body] = env[:body].read if env[:body].respond_to? :read
      end

      def request(env)
        ssl_verifyhost = (env[:ssl] && env[:ssl].fetch(:verify, true)) ? 2 : 0
        req = ::Typhoeus::Request.new env[:url].to_s,
          :method  => env[:method],
          :body    => env[:body],
          :headers => env[:request_headers],
          :ssl_verifyhost => ssl_verifyhost

        configure_ssl     req, env
        configure_proxy   req, env
        configure_timeout req, env
        configure_socket  req, env

        req.on_complete do |resp|
          if resp.timed_out?
            if parallel?(env)
              # TODO: error callback in async mode
            else
              raise Faraday::Error::TimeoutError, "request timed out"
            end
          end

          save_response(env, resp.code, resp.body) do |response_headers|
            response_headers.parse resp.response_headers
          end
          # in async mode, :response is initialized at this point
          env[:response].finish(env) if parallel?(env)
        end

        req
      end

      def configure_ssl(req, env)
        ssl = env[:ssl]

        req.sslversion = ssl[:version]          if ssl[:version]
        req.sslcert    = ssl[:client_cert_file] if ssl[:client_cert_file]
        req.sslkey     = ssl[:client_key_file]  if ssl[:client_key_file]
        req.cainfo     = ssl[:ca_file]          if ssl[:ca_file]
        req.capath     = ssl[:ca_path]          if ssl[:ca_path]
      end

      def configure_proxy(req, env)
        proxy = request_options(env)[:proxy]
        return unless proxy

        req.proxy = "#{proxy[:uri].host}:#{proxy[:uri].port}"

        if proxy[:username] && proxy[:password]
          req.proxyuserpwd = "#{proxy[:username]}:#{proxy[:password]}"
        end
      end

      def configure_timeout(req, env)
        env_req = request_options(env)
        req.options[:timeout_ms] = (env_req[:timeout] * 1000)             if env_req[:timeout]
        req.options[:connecttimeout_ms] = (env_req[:open_timeout] * 1000) if env_req[:open_timeout]
      end

      def configure_socket(req, env)
        if bind = request_options(env)[:bind]
          req.interface = bind[:host]
        end
      end

      def request_options(env)
        env[:request]
      end

      def parallel?(env)
        !!env[:parallel_manager]
      end
    end
  end
end
