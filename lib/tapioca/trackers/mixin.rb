# typed: true
# frozen_string_literal: true

module Tapioca
  module Trackers
    module Mixin
      extend T::Sig

      @mixin_map = {}.compare_by_identity
      @constant_map = {}.compare_by_identity

      class Type < T::Enum
        enums do
          Prepend = new
          Include = new
          Extend = new
        end
      end

      sig do
        params(
          constant: Module,
          mod: Module,
          mixin_type: Type
        ).void
      end
      def self.register(constant, mod, mixin_type)
        location = Tapioca::Reflection.required_from_location

        locs = mixin_locations_for(constant)
        locs.fetch(mixin_type).store(mod, location)

        constants = constants_with_mixin(mod)
        constants << [constant, mixin_type, location]
      end

      sig { params(mixin: Module).returns(T::Array[[Module, Type, String]]) }
      def self.constants_with_mixin(mixin)
        @constant_map[mixin] ||= []
      end

      sig { params(constant: Module).returns(T::Hash[Type, T::Hash[Module, String]]) }
      def self.mixin_locations_for(constant)
        @mixin_map[constant] ||= {
          Type::Prepend => {}.compare_by_identity,
          Type::Include => {}.compare_by_identity,
          Type::Extend => {}.compare_by_identity,
        }
      end
    end
  end
end

class Module
  prepend(Module.new do
    def prepend_features(constant)
      Tapioca::Trackers::Mixin.register(constant, self, Tapioca::Trackers::Mixin::Type::Prepend)
      super
    end

    def append_features(constant)
      Tapioca::Trackers::Mixin.register(constant, self, Tapioca::Trackers::Mixin::Type::Include)
      super
    end

    def extend_object(obj)
      Tapioca::Trackers::Mixin.register(obj, self, Tapioca::Trackers::Mixin::Type::Extend) if Module === obj
      super
    end
  end)
end
