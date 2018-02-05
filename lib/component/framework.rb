require "component/framework/version"
require "component/settings"

module Component
  module Framework

    COMPONENT_IMAGE_ASSETS = lambda do |logical_path, filename|
      filename.start_with?(components_base_dir.to_s) &&
          %w(.png .jpg .jpeg .gif).include?(File.extname(logical_path))
    end


    def self.components_base_dir
      @base_dir ||= Rails.root.join("components")
    end


    def self.initialize(application, assets_pipeline: true)

      # patch Rails
      require "component/framework/railtie"

      log("Components Initialization Started")
      log("Components Path: #{components_base_dir}")

      # add eager and autoload path that will allow to eager load and resolve components with namespaces.
      application.config.paths.add components_base_dir.to_s, eager_load: true

      log("Discovered Components: #{get_component_names.join(", ")}")

      log("Register DB Migrations")
      _get_component_migrations_paths.each { |path| application.config.paths["db/migrate"].push(path) }

      log("Register Components Routes")
      application.config.paths["config/routes.rb"].unshift(*_get_component_routing_paths)

      log("Register Components Helpers")
      application.config.paths["app/helpers"].unshift(*_get_component_helpers_paths)

      if assets_pipeline
        _initialize_assets_pipeline(application)
      end

      # Initialize components after all initialization finished.
      application.config.after_initialize do |app|

        log("Load Components Initializers")
        _load_components_initializers

        components = get_component_modules
        log("Initialize Components")
        components.each {|component| component.send("init") if component.respond_to?("init") }

        log("Post-Initialize Components")
        components.each {|component| component.send("ready") if component.respond_to?("ready") }

        log("Components Initialization Done")
      end

      log("Configuration Finished")
    end


    def self.get_component_names
      Dir.entries(components_base_dir)
          .select { |entry| (entry !="." && entry != "..") and File.directory? components_base_dir.join(entry) }
    end


    def self.get_component_modules
      get_component_names.map { |name| component_module_by_name(name) }
    end


    def self.component_module_by_name(name)
      return name.camelize.constantize
    rescue NameError, ArgumentError
      message = "Component #{name} not found"
      log(message)
      raise ComponentNotFoundError, message
    end


    private


    def self._initialize_assets_pipeline(application)

      log("Register Components Assets")
      application.config.assets.paths += _get_component_assets_paths
      application.config.assets.precompile += [COMPONENT_IMAGE_ASSETS]


      # We need to override SassC configuration
      # so we need to register after SassC app.config.assets.configure
      application.initializer :setup_component_sass, group: :all, after: :setup_sass do |app|

        require "component/framework/directive_processor"

        app.config.assets.configure do |sprockets_env|
          Component::Framework.log("Register assets directive processors")
          sprockets_env.unregister_preprocessor "application/javascript", Sprockets::DirectiveProcessor
          sprockets_env.unregister_preprocessor "text/css", Sprockets::DirectiveProcessor

          sprockets_env.register_preprocessor "application/javascript", Component::Framework::DirectiveProcessor
          sprockets_env.register_preprocessor "text/css", Component::Framework::DirectiveProcessor

          if Component::Framework.sass_present?
            require "component/framework/sass_importer"
            Component::Framework.log("Add .scss `@import all-components` support")
            sprockets_env.register_transformer "text/scss", "text/css", Component::Framework::ScssTemplate.new
            sprockets_env.register_engine(".scss", Component::Framework::ScssTemplate, { silence_deprecation: true })
          end
        end
      end
    end


    def self._get_component_migrations_paths
      _existing_component_subpaths("migrations")
    end


    def self._get_component_helpers_paths
      _existing_component_subpaths("api/helpers")
    end


    def self._get_component_assets_paths
      styles = _existing_component_subpaths("assets/stylesheets")
      scripts = _existing_component_subpaths("assets/javascripts")
      images = _existing_component_subpaths("assets/images")
      return styles + scripts + images
    end


    def self._get_component_routing_paths
      # All routes.rb files under /components folder
      Dir.glob(components_base_dir.join("**/routes.rb"))
    end


    def self._load_components_initializers
      # initializers are optional, so ignore the missing ones
      get_component_names.each do |name|
        begin
          require_relative(components_base_dir.join("#{name}/initialize"))
        rescue LoadError
        end
      end
    end


    def self._existing_component_subpaths(subpath)
      get_component_names.map { |component| components_base_dir.join(component, subpath).to_s }
          .select { |path| File.exists?(path) }
    end


    def self.sass_present?
      defined?(SassC)
    end


    def self.log(message)
      message = "[CF init] " + message
      if Rails.logger
        Rails.logger.info(message)
      else
        puts message
      end
    end

  end


  class ComponentNotFoundError < StandardError; end

end
