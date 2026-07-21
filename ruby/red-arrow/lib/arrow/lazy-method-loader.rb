# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements. See the NOTICE file distributed with this
# work for additional information regarding copyright ownership. The ASF
# licenses this file to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

require "monitor"

# Split GObjectIntrospection loading into two phases:
#   Eager (at require time): define_class only — GType registration + Ruby
#     class/module creation. Cheap.
#   Lazy (on first use): load_methods — Invoker.new + define_method for every
#     class, then run deferred post_load (require_libraries, arrow.so, etc.).
#
# libraries.rb has ~83 alias_method calls across 44 files that reference GI
# methods at class-body level, so ALL methods must be loaded before
# require_libraries runs. finalize() loads every stored class's methods in
# one pass, then calls run_deferred_post_load.
module Arrow
  module LazyMethodLoader
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def lazy_infos; @lazy_infos ||= {}; end
      def load_monitor; @load_monitor ||= Monitor.new; end
      def finalized?; @finalized ||= false; end

      # Triggered by method_missing / respond_to_missing? / new / const_missing.
      # Monitor (reentrant) is the key concurrency fix: cross-thread callers
      # block until finalize fully completes; same-thread re-entry (e.g.
      # require_libraries referencing a base-module constant → const_missing)
      # re-enters the Monitor, sees @finalized = true, returns immediately.
      def load_methods_for(klass)
        load_monitor.synchronize do
          return if finalized?
          @finalized = true
          base = Object.const_get(name.split("::").first)
          loader = new(base)
          lazy_infos.each do |k, info|
            loader.send(:load_virtual_functions, info, k)
            loader.send(:load_fields, info, k) if info.respond_to?(:n_fields)
            loader.send(:load_methods, info, k)
            loader.send(:post_prepare_class, k)
            post_lazy_load(k)
            remove_lazy_triggers(k)
          end
          run_deferred_post_load
        end
      end

      def run_deferred_post_load; end
      def post_lazy_load(klass); end

      def install_const_missing(base_module)
        lc = self
        base_module.define_singleton_method(:const_missing) do |name|
          lc.load_methods_for(nil)
          base_module.const_defined?(name) ? base_module.const_get(name) : super(name)
        end
      end

      private

      def install_lazy_triggers(klass)
        lc = self
        klass.define_method(:method_missing) do |name, *args, &block|
          lc.load_methods_for(self.class)
          if self.class.method_defined?(name) || self.class.private_method_defined?(name)
            send(name, *args, &block)
          else
            super(name, *args, &block)
          end
        end

        klass.define_method(:respond_to_missing?) do |name, inc_priv = false|
          lc.load_methods_for(self.class)
          self.class.method_defined?(name) ||
            (inc_priv && self.class.private_method_defined?(name))
        end

        klass.define_singleton_method(:new) do |*args, &block|
          lc.load_methods_for(klass)
          # finalize removes ALL new shims (including parent classes') before
          # returning, so klass.new now dispatches to Class#new directly.
          klass.new(*args, &block)
        end
      end

      def remove_lazy_triggers(klass)
        %i[method_missing respond_to_missing?].each do |m|
          begin
            if klass.method_defined?(m) && klass.instance_method(m).owner == klass
              klass.send(:remove_method, m)
            end
          rescue NameError
          end
        end
        # Remove the new shim from the singleton class so klass.new
        # dispatches to Class#new (bypasses inherited parent shims).
        begin
          klass.singleton_class.send(:remove_method, :new)
        rescue NameError
        end
      end
    end

    private

    def load_object_info(info)
      return if info.gtype == GLib::Type::NONE
      return if info.fundamental? && !info.gtype.instantiatable?
      klass = self.class.define_class(info.gtype, rubyish_class_name(info), @base_module)
      pre_prepare_class(klass)
      self.class.lazy_infos[klass] = info
      self.class.send(:install_lazy_triggers, klass)
    end

    def load_interface_info(info)
      return if info.gtype == GLib::Type::NONE
      mod = self.class.define_interface(info.gtype, rubyish_class_name(info), @base_module)
      pre_prepare_class(mod)
      self.class.lazy_infos[mod] = info
    end

    # Skip *Class structs: parent freezes singleton INVOKERS, which would
    # break later lazy load_methods. Regular structs stay eager (few, cheap).
    def load_struct_info(info)
      return if info.name.end_with?("Class")
      super
    end

    def post_load(repository, namespace)
    end
  end
end
