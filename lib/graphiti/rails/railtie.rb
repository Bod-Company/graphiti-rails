# frozen_string_literal: true

module Graphiti
  module Rails
    # This Railtie exposes
    # `config.graphiti.handled_exception_formats` which defaults to `[:jsonapi]`.
    # Formats in this list will always have their exceptions handled by Graphiti.
    class Railtie < ::Rails::Railtie
      config.graphiti = ActiveSupport::OrderedOptions.new

      config.graphiti.handled_exception_formats = [:jsonapi]

      rake_tasks do
        load File.expand_path("../../tasks/graphiti.rake", __dir__)
      end

      initializer "graphiti-rails.handled_exception_formats" do |app|
        Graphiti::Rails.handled_exception_formats = app.config.graphiti.handled_exception_formats
      end

      initializer "graphti-rails.logger" do
        config.after_initialize do
          Graphiti.logger = ::Rails.logger
        end
      end

      initializer "graphiti-rails.init" do
        if ::Rails.application.config.eager_load
          config.after_initialize do |app|
            ::Rails.application.reload_routes!
            Graphiti.setup!
          end
        end

        register_parameter_parser
        register_renderers
        establish_concurrency
        configure_endpoint_lookup
      end

      # from jsonapi-rails
      PARSER = lambda do |body|
        data = JSON.parse(body)
        data[:format] = :jsonapi
        data.with_indifferent_access
      end

      def register_parameter_parser
        if ::Rails::VERSION::MAJOR >= 5
          ActionDispatch::Request.parameter_parsers[:jsonapi] = PARSER
        else
          ActionDispatch::ParamsParser::DEFAULT_PARSERS[Mime[:jsonapi]] = PARSER
        end
      end

      def register_renderers
        ActiveSupport.on_load(:action_controller) do
          ::ActionController::Renderers.add(:jsonapi) do |proxy, options|
            self.content_type ||= Mime[:jsonapi]

            # opts = {}
            # if respond_to?(:default_jsonapi_render_options)
            #   opts = default_jsonapi_render_options
            # end

            if proxy.is_a?(Hash) # for destroy
              render(options.merge(json: proxy))
            else
              proxy.to_jsonapi(options)
            end
          end
        end

        ActiveSupport.on_load(:action_controller) do
          ActionController::Renderers.add(:jsonapi_errors) do |proxy, options|
            self.content_type ||= Mime[:jsonapi]

            validation = GraphitiErrors::Validation::Serializer.new \
              proxy.data, proxy.payload.relationships

            render \
              json: {errors: validation.errors},
              status: :unprocessable_entity
          end
        end
      end

      # Only run concurrently if our environment supports it
      def establish_concurrency
        Graphiti.config.concurrency = !::Rails.env.test? &&
          ::Rails.application.config.cache_classes
      end

      def configure_endpoint_lookup
        Graphiti.config.context_for_endpoint = ->(path, action) {
          method = :GET
          case action
            when :show then path = "#{path}/1"
            when :create then method = :POST
            when :update
              path = "#{path}/1"
              method = :PUT
            when :destroy
              path = "#{path}/1"
              method = :DELETE
          end

          route = begin
                    ::Rails.application.routes.recognize_path(path, method: method)
                  rescue
                    nil
                  end
          "#{route[:controller]}_controller".classify.safe_constantize if route
        }
      end
    end
  end
end
