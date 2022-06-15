# typed: strict
# frozen_string_literal: true

module Tapioca
  module Gem
    class Pipeline
      extend T::Sig
      include Runtime::Reflection
      include RBIHelper

      IGNORED_SYMBOLS = T.let(["YAML", "MiniTest", "Mutex"], T::Array[String])

      sig { returns(Gemfile::GemSpec) }
      attr_reader :gem

      sig { params(gem: Gemfile::GemSpec, include_doc: T::Boolean).void }
      def initialize(gem, include_doc: false)
        @root = T.let(RBI::Tree.new, RBI::Tree)
        @gem = gem
        @seen = T.let(Set.new, T::Set[String])
        @alias_namespace = T.let(Set.new, T::Set[String])

        @events = T.let([], T::Array[Gem::Event])

        @payload_symbols = T.let(Static::SymbolLoader.payload_symbols, T::Set[String])
        @bootstrap_symbols = T.let(Static::SymbolLoader.gem_symbols(@gem).union(Static::SymbolLoader.engine_symbols),
          T::Set[String])
        @bootstrap_symbols.each { |symbol| push_symbol(symbol) }

        @node_listeners = T.let([], T::Array[Gem::Listeners::Base])
        @node_listeners << Gem::Listeners::SorbetTypeVariables.new(self)
        @node_listeners << Gem::Listeners::Mixins.new(self)
        @node_listeners << Gem::Listeners::DynamicMixins.new(self)
        @node_listeners << Gem::Listeners::Methods.new(self)
        @node_listeners << Gem::Listeners::SorbetHelpers.new(self)
        @node_listeners << Gem::Listeners::SorbetEnums.new(self)
        @node_listeners << Gem::Listeners::SorbetProps.new(self)
        @node_listeners << Gem::Listeners::SorbetRequiredAncestors.new(self)
        @node_listeners << Gem::Listeners::SorbetSignatures.new(self)
        @node_listeners << Gem::Listeners::Subconstants.new(self)
        @node_listeners << Gem::Listeners::YardDoc.new(self) if include_doc
        @node_listeners << Gem::Listeners::ForeignConstants.new(self)
        @node_listeners << Gem::Listeners::RemoveEmptyPayloadScopes.new(self)
      end

      sig { returns(RBI::Tree) }
      def compile
        dispatch(next_event) until @events.empty?
        @root
      end

      # Events handling

      sig { params(symbol: String).void }
      def push_symbol(symbol)
        @events << Gem::SymbolFound.new(symbol)
      end

      sig { params(symbol: String, constant: BasicObject).void.checked(:never) }
      def push_constant(symbol, constant)
        @events << Gem::ConstantFound.new(symbol, constant)
      end

      sig { params(symbol: String, constant: Module).void.checked(:never) }
      def push_foreign_constant(symbol, constant)
        @events << Gem::ForeignConstantFound.new(symbol, constant)
      end

      sig { params(symbol: String, constant: Module, node: RBI::Const).void.checked(:never) }
      def push_const(symbol, constant, node)
        @events << Gem::ConstNodeAdded.new(symbol, constant, node)
      end

      sig do
        params(symbol: String, constant: Module, node: RBI::Scope).void.checked(:never)
      end
      def push_scope(symbol, constant, node)
        @events << Gem::ScopeNodeAdded.new(symbol, constant, node)
      end

      sig do
        params(symbol: String, constant: Module, node: RBI::Scope).void.checked(:never)
      end
      def push_foreign_scope(symbol, constant, node)
        @events << Gem::ForeignScopeNodeAdded.new(symbol, constant, node)
      end

      sig do
        params(
          symbol: String,
          constant: Module,
          node: RBI::Method,
          signature: T.untyped,
          parameters: T::Array[[Symbol, String]]
        ).void.checked(:never)
      end
      def push_method(symbol, constant, node, signature, parameters)
        @events << Gem::MethodNodeAdded.new(symbol, constant, node, signature, parameters)
      end

      # Constants and properties filtering

      sig { params(symbol_name: String).returns(T::Boolean) }
      def symbol_in_payload?(symbol_name)
        symbol_name = symbol_name[2..-1] if symbol_name.start_with?("::")
        return false unless symbol_name

        @payload_symbols.include?(symbol_name)
      end

      sig { params(method: UnboundMethod).returns(T::Boolean) }
      def method_in_gem?(method)
        source_location = method.source_location&.first
        return false if source_location.nil?

        @gem.contains_path?(source_location)
      end

      # Helpers

      sig { params(constant: Module).returns(T.nilable(String)) }
      def name_of(constant)
        name = name_of_proxy_target(constant, super(class_of(constant)))
        return name if name

        name = super(constant)
        return if name.nil?
        return unless are_equal?(constant, constantize(name, inherit: true))

        name = "Struct" if name =~ /^(::)?Struct::[^:]+$/
        name
      end

      private

      # Events handling

      sig { returns(Gem::Event) }
      def next_event
        T.must(@events.shift)
      end

      sig { params(event: Gem::Event).void }
      def dispatch(event)
        case event
        when Gem::SymbolFound
          on_symbol(event)
        when Gem::ConstantFound
          on_constant(event)
        when Gem::NodeAdded
          on_node(event)
        else
          raise "Unsupported event #{event.class}"
        end
      end

      sig { params(event: Gem::SymbolFound).void }
      def on_symbol(event)
        symbol = event.symbol.delete_prefix("::")
        return if skip_symbol?(symbol)

        constant = constantize(symbol)
        push_constant(symbol, constant) if constant
      end

      sig { params(event: Gem::ConstantFound).void.checked(:never) }
      def on_constant(event)
        name = event.symbol
        return if skip_constant?(name, event.constant)

        mark_seen(name)

        if event.is_a?(Gem::ForeignConstantFound)
          compile_foreign_constant(name, event.constant)
        else
          compile_constant(name, event.constant)
        end
      end

      sig { params(event: Gem::NodeAdded).void }
      def on_node(event)
        @node_listeners.each { |listener| listener.dispatch(event) }
      end

      # Compiling

      sig { params(symbol: String, constant: Module).void }
      def compile_foreign_constant(symbol, constant)
        return if skip_foreign_constant?(symbol, constant)

        scope = compile_scope(symbol, constant)
        push_foreign_scope(symbol, constant, scope)
      end

      sig { params(symbol: String, constant: BasicObject).void.checked(:never) }
      def compile_constant(symbol, constant)
        case constant
        when Module
          if name_of(constant) != symbol
            compile_alias(symbol, constant)
          else
            compile_module(symbol, constant)
          end
        else
          compile_object(symbol, constant)
        end
      end

      sig { params(name: String, constant: Module).void }
      def compile_alias(name, constant)
        return if skip_alias?(name, constant)

        target = name_of(constant)
        # If target has no name, let's make it an anonymous class or module with `Class.new` or `Module.new`
        target = "#{constant.class}.new" unless target

        add_to_alias_namespace(name)

        return if IGNORED_SYMBOLS.include?(name)

        node = RBI::Const.new(name, target)
        push_const(name, constant, node)
        @root << node
      end

      sig { params(name: String, value: BasicObject).void.checked(:never) }
      def compile_object(name, value)
        return if skip_object?(name, value)

        klass = class_of(value)

        klass_name = if klass == ObjectSpace::WeakMap
          # WeakMap is an implicit generic with one type variable
          "ObjectSpace::WeakMap[T.untyped]"
        elsif T::Generic === klass
          generic_name_of(klass)
        else
          name_of(klass)
        end

        if klass_name == "T::Private::Types::TypeAlias"
          type_alias = sanitize_signature_types(T.unsafe(value).aliased_type.to_s)
          node = RBI::Const.new(name, "T.type_alias { #{type_alias} }")
          push_const(name, klass, node)
          @root << node
          return
        end

        return if klass_name&.start_with?("T::Types::", "T::Private::")

        type_name = klass_name || "T.untyped"
        node = RBI::Const.new(name, "T.let(T.unsafe(nil), #{type_name})")
        push_const(name, klass, node)
        @root << node
      end

      sig { params(name: String, constant: Module).void }
      def compile_module(name, constant)
        return if skip_module?(name, constant)

        scope = compile_scope(name, constant)
        push_scope(name, constant, scope)
      end

      sig { params(name: String, constant: Module).returns(RBI::Scope) }
      def compile_scope(name, constant)
        scope = if constant.is_a?(Class)
          superclass = compile_superclass(constant)
          RBI::Class.new(name, superclass_name: superclass)
        else
          RBI::Module.new(name)
        end

        @root << scope

        scope
      end

      sig { params(constant: Class).returns(T.nilable(String)) }
      def compile_superclass(constant)
        superclass = T.let(nil, T.nilable(Class)) # rubocop:disable Lint/UselessAssignment

        while (superclass = superclass_of(constant))
          constant_name = name_of(constant)
          constant = superclass

          # Some types have "themselves" as their superclass
          # which can happen via:
          #
          # class A < Numeric; end
          # A = Class.new(A)
          # A.superclass #=> A
          #
          # We compare names here to make sure we skip those
          # superclass instances and walk up the chain.
          #
          # The name comparison is against the name of the constant
          # resolved from the name of the superclass, since
          # this is also possible:
          #
          # B = Class.new
          # class A < B; end
          # B = A
          # A.superclass.name #=> "B"
          # B #=> A
          superclass_name = name_of(superclass)
          next unless superclass_name

          resolved_superclass = constantize(superclass_name)
          next unless Module === resolved_superclass
          next if name_of(resolved_superclass) == constant_name

          # We found a suitable superclass
          break
        end

        return if superclass == ::Object || superclass == ::Delegator
        return if superclass.nil?

        name = name_of(superclass)
        return if name.nil? || name.empty?

        push_symbol(name)

        "::#{name}"
      end

      # Constants and properties filtering

      sig { params(name: String).returns(T::Boolean) }
      def skip_symbol?(name)
        symbol_in_payload?(name) && !@bootstrap_symbols.include?(name)
      end

      sig { params(name: String, constant: BasicObject).returns(T::Boolean).checked(:never) }
      def skip_constant?(name, constant)
        return true if name.strip.empty?
        return true if name.start_with?("#<")
        return true if name.downcase == name
        return true if alias_namespaced?(name)
        return true if seen?(name)

        return true if T::Enum === constant # T::Enum instances are defined via `compile_enums`

        false
      end

      sig { params(name: String, constant: Module).returns(T::Boolean) }
      def skip_alias?(name, constant)
        symbol_in_payload?(name)
      end

      sig { params(name: String, constant: BasicObject).returns(T::Boolean).checked(:never) }
      def skip_object?(name, constant)
        symbol_in_payload?(name)
      end

      sig { params(name: String, constant: Module).returns(T::Boolean) }
      def skip_foreign_constant?(name, constant)
        Tapioca::TypeVariableModule === constant
      end

      sig { params(name: String, constant: Module).returns(T::Boolean) }
      def skip_module?(name, constant)
        Tapioca::TypeVariableModule === constant || !defined_in_gem?(constant, strict: false)
      end

      sig { params(constant: Module, strict: T::Boolean).returns(T::Boolean) }
      def defined_in_gem?(constant, strict: true)
        files = Set.new(get_file_candidates(constant))
          .merge(Runtime::Trackers::ConstantDefinition.files_for(constant))

        return !strict if files.empty?

        files.any? do |file|
          @gem.contains_path?(file)
        end
      end

      sig { params(constant: Module).returns(T::Array[String]) }
      def get_file_candidates(constant)
        wrapped_module = Pry::WrappedModule.new(constant)

        wrapped_module.candidates.map(&:file).to_a.compact
      rescue ArgumentError, NameError
        []
      end

      sig { params(name: String).void }
      def add_to_alias_namespace(name)
        @alias_namespace.add("#{name}::")
      end

      sig { params(name: String).returns(T::Boolean) }
      def alias_namespaced?(name)
        @alias_namespace.any? do |namespace|
          name.start_with?(namespace)
        end
      end

      sig { params(name: String).void }
      def mark_seen(name)
        @seen.add(name)
      end

      sig { params(name: String).returns(T::Boolean) }
      def seen?(name)
        @seen.include?(name)
      end

      # Helpers

      sig { params(constant: T.all(Module, T::Generic)).returns(String) }
      def generic_name_of(constant)
        type_name = T.must(constant.name)
        return type_name if type_name =~ /\[.*\]$/

        type_variables = Runtime::GenericTypeRegistry.lookup_type_variables(constant)
        return type_name unless type_variables

        type_variable_names = type_variables.map { "T.untyped" }.join(", ")

        "#{type_name}[#{type_variable_names}]"
      end

      sig { params(constant: Module, class_name: T.nilable(String)).returns(T.nilable(String)) }
      def name_of_proxy_target(constant, class_name)
        return unless class_name == "ActiveSupport::Deprecation::DeprecatedConstantProxy"

        # We are dealing with a ActiveSupport::Deprecation::DeprecatedConstantProxy
        # so try to get the name of the target class
        begin
          target = constant.__send__(:target)
        rescue NoMethodError
          return
        end

        name_of(target)
      end
    end
  end
end
