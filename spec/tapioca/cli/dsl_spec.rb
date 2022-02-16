# typed: true
# frozen_string_literal: true

require "spec_helper"

module Tapioca
  class DslSpec < SpecWithProject
    describe "cli::dsl" do
      before(:all) do
        @project.write("config/application.rb", <<~RB)
          module Rails
            class Application
              attr_reader :config

              def load_tasks; end
            end

            def self.application
              Application.new
            end
          end

          lib_dir = File.expand_path("../lib/", __dir__)

          # Add lib directory to load path
          $LOAD_PATH << lib_dir

          # Require files from lib directory
          Dir.glob("**/*.rb", base: lib_dir).sort.each do |file|
            require(file)
          end
        RB

        @project.write("config/environment.rb", <<~RB)
          require_relative "application.rb"
        RB
      end

      describe "generate" do
        before(:all) do
          @project.require_real_gem("smart_properties", "1.15.0")
          @project.require_real_gem("sidekiq", "6.2.1")
          @project.bundle_install
        end

        after do
          @project.remove("db")
          @project.remove("lib")
          @project.remove("sorbet/rbi/dsl")
        end

        it "does not generate anything if there are no matching constants" do
          @project.write("lib/user.rb", <<~RB)
            class User; end
          RB

          result = @project.tapioca("dsl User")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

          OUT

          assert_equal(<<~ERR, result.err)
            No classes/modules can be matched for RBI generation.
            Please check that the requested classes/modules include processable DSL methods.
          ERR

          refute_project_file_exist("sorbet/rbi/dsl/user.rbi")

          refute_success_status(result)
        end

        it "generates RBI files for only required constants" do
          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          result = @project.tapioca("dsl Post")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

                  create  sorbet/rbi/dsl/post.rbi

            Done
            All operations performed in working directory.
            Please review changes and commit them.
          OUT

          assert_empty_stderr(result)

          assert_project_file_equal("sorbet/rbi/dsl/post.rbi", <<~RBI)
            # typed: true

            # DO NOT EDIT MANUALLY
            # This is an autogenerated file for dynamic methods in `Post`.
            # Please instead update this file by running `bin/tapioca dsl Post`.

            class Post
              include SmartPropertiesGeneratedMethods

              module SmartPropertiesGeneratedMethods
                sig { returns(T.nilable(::String)) }
                def title; end

                sig { params(title: T.nilable(::String)).returns(T.nilable(::String)) }
                def title=(title); end
              end
            end
          RBI

          assert_success_status(result)
        end

        it "errors for unprocessable required constants" do
          result = @project.tapioca("dsl NonExistent::Foo NonExistent::Bar NonExistent::Baz")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

            Error: Cannot find constant 'NonExistent::Foo'
            Error: Cannot find constant 'NonExistent::Bar'
            Error: Cannot find constant 'NonExistent::Baz'
          OUT

          assert_empty_stderr(result) # FIXME: Shouldn't the errors be printed here?

          refute_project_file_exist("sorbet/rbi/dsl/non_existent/foo.rbi")
          refute_project_file_exist("sorbet/rbi/dsl/non_existent/bar.rbi")
          refute_project_file_exist("sorbet/rbi/dsl/non_existent/baz.rbi")

          refute_success_status(result)
        end

        it "removes RBI files for unprocessable required constants" do
          @project.write("sorbet/rbi/dsl/non_existent/foo.rbi")
          @project.write("sorbet/rbi/dsl/non_existent/baz.rbi")

          result = @project.tapioca("dsl NonExistent::Foo NonExistent::Bar NonExistent::Baz")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

            Error: Cannot find constant 'NonExistent::Foo'
                  remove  sorbet/rbi/dsl/non_existent/foo.rbi
            Error: Cannot find constant 'NonExistent::Bar'
            Error: Cannot find constant 'NonExistent::Baz'
                  remove  sorbet/rbi/dsl/non_existent/baz.rbi
          OUT

          assert_empty_stderr(result) # FIXME: Shouldn't the errors be printed here?

          refute_project_file_exist("sorbet/rbi/dsl/non_existent/foo.rbi")
          refute_project_file_exist("sorbet/rbi/dsl/non_existent/baz.rbi")

          refute_success_status(result)
        end

        it "generates RBI files for all processable constants" do
          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          @project.write("lib/comment.rb", <<~RB)
            require "smart_properties"

            module Namespace
              class Comment
                include SmartProperties
                property! :body, accepts: String
              end
            end
          RB

          result = @project.tapioca("dsl")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

                  create  sorbet/rbi/dsl/namespace/comment.rbi
                  create  sorbet/rbi/dsl/post.rbi

            Done
            All operations performed in working directory.
            Please review changes and commit them.
          OUT

          assert_empty_stderr(result)

          assert_project_file_equal("sorbet/rbi/dsl/post.rbi", <<~RBI)
            # typed: true

            # DO NOT EDIT MANUALLY
            # This is an autogenerated file for dynamic methods in `Post`.
            # Please instead update this file by running `bin/tapioca dsl Post`.

            class Post
              include SmartPropertiesGeneratedMethods

              module SmartPropertiesGeneratedMethods
                sig { returns(T.nilable(::String)) }
                def title; end

                sig { params(title: T.nilable(::String)).returns(T.nilable(::String)) }
                def title=(title); end
              end
            end
          RBI

          assert_project_file_equal("sorbet/rbi/dsl/namespace/comment.rbi", <<~RBI)
            # typed: true

            # DO NOT EDIT MANUALLY
            # This is an autogenerated file for dynamic methods in `Namespace::Comment`.
            # Please instead update this file by running `bin/tapioca dsl Namespace::Comment`.

            class Namespace::Comment
              include SmartPropertiesGeneratedMethods

              module SmartPropertiesGeneratedMethods
                sig { returns(::String) }
                def body; end

                sig { params(body: ::String).returns(::String) }
                def body=(body); end
              end
            end
          RBI

          assert_success_status(result)
        end

        it "generates RBI files for processable constants coming from gems" do
          gem = mock_gem("foo", "1.0.0") do
            write("lib/foo/role.rb", <<~RB)
              require "smart_properties"

              module Foo
                class Role
                  include SmartProperties
                  property :title, accepts: String
                end
              end
            RB
          end

          @project.write("lib/post.rb", <<~RB)
            require "foo/role"
          RB

          @project.require_mock_gem(gem)

          result = @project.tapioca("dsl")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

                  create  sorbet/rbi/dsl/foo/role.rbi

            Done
            All operations performed in working directory.
            Please review changes and commit them.
          OUT

          assert_empty_stderr(result)

          assert_project_file_equal("sorbet/rbi/dsl/foo/role.rbi", <<~RBI)
            # typed: true

            # DO NOT EDIT MANUALLY
            # This is an autogenerated file for dynamic methods in `Foo::Role`.
            # Please instead update this file by running `bin/tapioca dsl Foo::Role`.

            class Foo::Role
              include SmartPropertiesGeneratedMethods

              module SmartPropertiesGeneratedMethods
                sig { returns(T.nilable(::String)) }
                def title; end

                sig { params(title: T.nilable(::String)).returns(T.nilable(::String)) }
                def title=(title); end
              end
            end
          RBI

          assert_success_status(result)
        end

        it "generates RBI files in the correct output directory" do
          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          @project.write("lib/comment.rb", <<~RB)
            require "smart_properties"

            module Namespace
              class Comment
                include SmartProperties
                property! :body, accepts: String
              end
            end
          RB

          result = @project.tapioca("dsl --verbose --outdir rbis/")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

              processing  Namespace::Comment
                  create  rbis/namespace/comment.rbi
              processing  Post
                  create  rbis/post.rbi

            Done
            All operations performed in working directory.
            Please review changes and commit them.
          OUT

          assert_empty_stderr(result)

          assert_project_file_exist("rbis/namespace/comment.rbi")
          assert_project_file_exist("rbis/post.rbi")

          assert_success_status(result)

          @project.remove("rbis/")
        end

        it "generates RBI files with verbose output" do
          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          @project.write("lib/comment.rb", <<~RB)
            require "smart_properties"

            module Namespace
              class Comment
                include SmartProperties
                property! :body, accepts: String
              end
            end
          RB

          result = @project.tapioca("dsl --verbose")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

              processing  Namespace::Comment
                  create  sorbet/rbi/dsl/namespace/comment.rbi
              processing  Post
                  create  sorbet/rbi/dsl/post.rbi

            Done
            All operations performed in working directory.
            Please review changes and commit them.
          OUT

          assert_empty_stderr(result)

          assert_project_file_exist("sorbet/rbi/dsl/post.rbi")
          assert_project_file_exist("sorbet/rbi/dsl/namespace/comment.rbi")

          assert_success_status(result)
        end

        it "can generates RBI files quietly" do
          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          result = @project.tapioca("dsl --quiet")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...


            Done
            All operations performed in working directory.
            Please review changes and commit them.
          OUT

          assert_empty_stderr(result)

          assert_project_file_exist("sorbet/rbi/dsl/post.rbi")

          assert_success_status(result)
        end

        it "generates RBI files without header" do
          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          @project.tapioca("dsl --no-file-header Post")

          assert_project_file_equal("sorbet/rbi/dsl/post.rbi", <<~RBI)
            # typed: true

            class Post
              include SmartPropertiesGeneratedMethods

              module SmartPropertiesGeneratedMethods
                sig { returns(T.nilable(::String)) }
                def title; end

                sig { params(title: T.nilable(::String)).returns(T.nilable(::String)) }
                def title=(title); end
              end
            end
          RBI
        end

        it "removes stale RBI files" do
          @project.write("sorbet/rbi/dsl/to_be_deleted/foo.rbi")
          @project.write("sorbet/rbi/dsl/to_be_deleted/baz.rbi")
          @project.write("sorbet/rbi/dsl/does_not_exist.rbi")

          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          result = @project.tapioca("dsl")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

                  create  sorbet/rbi/dsl/post.rbi

            Removing stale RBI files...
                  remove  sorbet/rbi/dsl/does_not_exist.rbi
                  remove  sorbet/rbi/dsl/to_be_deleted/baz.rbi
                  remove  sorbet/rbi/dsl/to_be_deleted/foo.rbi

            Done
            All operations performed in working directory.
            Please review changes and commit them.
          OUT

          assert_empty_stderr(result)

          refute_project_file_exist("sorbet/rbi/dsl/does_not_exist.rbi")
          refute_project_file_exist("sorbet/rbi/dsl/to_be_deleted/foo.rbi")
          refute_project_file_exist("sorbet/rbi/dsl/to_be_deleted/baz.rbi")
          assert_project_file_exist("sorbet/rbi/dsl/post.rbi")

          assert_success_status(result)
        end

        it "does not crash withg anonymous constants" do
          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          @project.write("lib/job.rb", <<~RB)
            require "sidekiq"

            Class.new do
              include Sidekiq::Worker
            end
          RB

          result = @project.tapioca("dsl")

          assert_empty_stderr(result)
          assert_success_status(result)

          assert_project_file_exist("sorbet/rbi/dsl/post.rbi")
        end

        it "removes stale RBIs properly when running in parallel" do
          # Files that shouldn't be deleted
          @project.write("sorbet/rbi/dsl/job.rbi")
          @project.write("sorbet/rbi/dsl/post.rbi")

          # Files that should be deleted
          @project.write("sorbet/rbi/dsl/to_be_deleted/foo.rbi")
          @project.write("sorbet/rbi/dsl/to_be_deleted/baz.rbi")
          @project.write("sorbet/rbi/dsl/does_not_exist.rbi")

          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          @project.write("lib/job.rb", <<~RB)
            require "sidekiq"

            class Job
              include Sidekiq::Worker
              def perform(foo, bar)
              end
            end
          RB

          result = @project.tapioca("dsl --workers 2")

          assert_empty_stderr(result)
          assert_success_status(result)

          assert_project_file_exist("sorbet/rbi/dsl/post.rbi")
          assert_project_file_exist("sorbet/rbi/dsl/job.rbi")

          refute_project_file_exist("sorbet/rbi/dsl/does_not_exist.rbi")
          refute_project_file_exist("sorbet/rbi/dsl/to_be_deleted/foo.rbi")
          refute_project_file_exist("sorbet/rbi/dsl/to_be_deleted/baz.rbi")
        end

        it "removes stale RBI files of requested constants" do
          @project.write("sorbet/rbi/dsl/user.rbi")

          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          @project.write("lib/user.rb", <<~RB)
            class User; end
          RB

          result = @project.tapioca("dsl Post User")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

                  create  sorbet/rbi/dsl/post.rbi

            Removing stale RBI files...
                  remove  sorbet/rbi/dsl/user.rbi

            Done
            All operations performed in working directory.
            Please review changes and commit them.
          OUT

          assert_empty_stderr(result)

          assert_project_file_exist("sorbet/rbi/dsl/post.rbi")
          refute_project_file_exist("sorbet/rbi/dsl/user.rbi")

          assert_success_status(result)
        end

        it "must run custom compilers" do
          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          @project.write("lib/compilers/compiler_that_includes_bar_module.rb", <<~RB)
            require "post"

            class CompilerThatIncludesBarModuleInPost < Tapioca::Dsl::Compiler
              extend T::Sig

              ConstantType = type_member(fixed: T.class_of(::Post))

              sig { override.void }
              def decorate
                root.create_path(constant) do |klass|
                  klass.create_module("GeneratedBar")
                  klass.create_include("GeneratedBar")
                end
              end

              sig { override.returns(T::Enumerable[Module]) }
              def self.gather_constants
                [::Post]
              end
            end
          RB

          @project.write("lib/compilers/compiler_that_includes_foo_module.rb", <<~RB)
            require "post"

            class CompilerThatIncludesFooModuleInPost < Tapioca::Dsl::Compiler
              extend T::Sig

              ConstantType = type_member(fixed: T.class_of(::Post))

              sig { override.void }
              def decorate
                root.create_path(constant) do |klass|
                  klass.create_module("GeneratedFoo")
                  klass.create_include("GeneratedFoo")
                end
              end

              sig { override.returns(T::Enumerable[Module]) }
              def self.gather_constants
                [::Post]
              end
            end
          RB

          result = @project.tapioca("dsl")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

                  create  sorbet/rbi/dsl/post.rbi

            Done
            All operations performed in working directory.
            Please review changes and commit them.
          OUT

          assert_empty_stderr(result)

          assert_project_file_equal("sorbet/rbi/dsl/post.rbi", <<~RBI)
            # typed: true

            # DO NOT EDIT MANUALLY
            # This is an autogenerated file for dynamic methods in `Post`.
            # Please instead update this file by running `bin/tapioca dsl Post`.

            class Post
              include GeneratedBar
              include GeneratedFoo
              include SmartPropertiesGeneratedMethods

              module GeneratedBar; end
              module GeneratedFoo; end

              module SmartPropertiesGeneratedMethods
                sig { returns(T.nilable(::String)) }
                def title; end

                sig { params(title: T.nilable(::String)).returns(T.nilable(::String)) }
                def title=(title); end
              end
            end
          RBI

          assert_success_status(result)
        end

        it "must respect `only` option" do
          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          @project.write("lib/job.rb", <<~RB)
            require "sidekiq"

            class Job
              include Sidekiq::Worker
              def perform(foo, bar)
              end
            end
          RB

          @project.write("lib/compilers/foo/compiler.rb", <<~RB)
            require "job"

            module Foo
              class Compiler < Tapioca::Dsl::Compiler
                extend T::Sig

                ConstantType = type_member(fixed: Job)

                sig { override.void }
                def decorate
                  root.create_path(constant) do |job|
                    job.create_module("FooModule")
                  end
                end

                sig { override.returns(T::Enumerable[Module]) }
                def self.gather_constants
                  [Job]
                end
              end
            end
          RB

          result = @project.tapioca("dsl --only SidekiqWorker Foo::Compiler")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

                  create  sorbet/rbi/dsl/job.rbi

            Done
            All operations performed in working directory.
            Please review changes and commit them.
          OUT

          assert_empty_stderr(result)

          assert_project_file_equal("sorbet/rbi/dsl/job.rbi", <<~RBI)
            # typed: true

            # DO NOT EDIT MANUALLY
            # This is an autogenerated file for dynamic methods in `Job`.
            # Please instead update this file by running `bin/tapioca dsl Job`.

            class Job
              class << self
                sig { params(foo: T.untyped, bar: T.untyped).returns(String) }
                def perform_async(foo, bar); end

                sig { params(interval: T.any(DateTime, Time), foo: T.untyped, bar: T.untyped).returns(String) }
                def perform_at(interval, foo, bar); end

                sig { params(interval: Numeric, foo: T.untyped, bar: T.untyped).returns(String) }
                def perform_in(interval, foo, bar); end
              end

              module FooModule; end
            end
          RBI

          refute_project_file_exist("sorbet/rbi/dsl/post.rbi")

          assert_success_status(result)
        end

        it "errors if there are no matching compilers" do
          result = @project.tapioca("dsl --only NonexistentCompiler")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

            Error: Cannot find compiler 'NonexistentCompiler'
          OUT

          assert_empty_stderr(result) # FIXME: Shouldn't the errors be printed here?
          refute_success_status(result)
        end

        it "must respect `exclude` option" do
          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          @project.write("lib/job.rb", <<~RB)
            require "sidekiq"

            class Job
              include Sidekiq::Worker
              def perform(foo, bar)
              end
            end
          RB

          @project.write("lib/compilers/foo/compiler.rb", <<~RB)
            require "job"

            module Foo
              class Compiler < Tapioca::Dsl::Compiler
                extend T::Sig

                ConstantType = type_member(fixed: Job)

                sig { override.void }
                def decorate
                  root.create_path(constant) do |job|
                    job.create_module("FooModule")
                  end
                end

                sig { override.returns(T::Enumerable[Module]) }
                def self.gather_constants
                  [Job]
                end
              end
            end
          RB

          result = @project.tapioca("dsl --exclude SidekiqWorker Foo::Compiler")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

                  create  sorbet/rbi/dsl/post.rbi

            Done
            All operations performed in working directory.
            Please review changes and commit them.
          OUT

          assert_empty_stderr(result)

          refute_project_file_exist("sorbet/rbi/dsl/job.rbi")
          assert_project_file_exist("sorbet/rbi/dsl/post.rbi")

          assert_success_status(result)
        end

        it "errors if there are no matching `exclude` compilers" do
          result = @project.tapioca("dsl --exclude NonexistentCompiler")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

            Error: Cannot find compiler 'NonexistentCompiler'
          OUT

          assert_empty_stderr(result) # FIXME: Shouldn't the errors be printed here?
          refute_success_status(result)
        end

        it "aborts if there are pending migrations" do
          @project.require_real_gem("rake", "13.0.6")
          @project.bundle_install

          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          @project.write("db/migrate/202001010000_create_articles.rb", <<~RB)
            class CreateArticles < ActiveRecord::Migration[6.1]
              def change
                create_table(:articles) do |t|
                  t.timestamps
                end
              end
            end
          RB

          @project.write("lib/database.rb", <<~RB)
            require "rake"

            namespace :db do
              task :abort_if_pending_migrations do
                pending_migrations = Dir["\#{Kernel.__dir__}/../db/migrate/*.rb"]

                if pending_migrations.any?
                  Kernel.puts "You have \#{pending_migrations.size} pending migration:"

                  pending_migrations.each do |pending_migration|
                    name = pending_migration.split("/").last
                    Kernel.puts name
                  end

                  Kernel.abort(%{Run `bin/rails db:migrate` to update your database then try again.})
                end
              end
            end
          RB

          result = @project.tapioca("dsl")

          # FIXME: print the error to the correct stream
          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            You have 1 pending migration:
            202001010000_create_articles.rb
          OUT

          assert_equal(<<~ERR, result.err)
            Run `bin/rails db:migrate` to update your database then try again.
          ERR

          refute_success_status(result)
        end

        it "overwrites existing RBIs without user input" do
          @project.write("sorbet/rbi/dsl/image.rbi")

          @project.write("lib/image.rb", <<~RB)
            require "smart_properties"

            class Image
              include SmartProperties

              property :title, accepts: String
              property :src, accepts: String
            end
          RB

          result = @project.tapioca("dsl")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Compiling DSL RBI files...

                   force  sorbet/rbi/dsl/image.rbi

            Done
            All operations performed in working directory.
            Please review changes and commit them.
          OUT

          assert_empty_stderr(result)

          assert_project_file_exist("sorbet/rbi/dsl/image.rbi")

          assert_success_status(result)
        end

        it "generates the correct RBIs when running in parallel" do
          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          @project.write("lib/job.rb", <<~RB)
            require "sidekiq"

            class Job
              include Sidekiq::Worker
              def perform(foo, bar)
              end
            end
          RB

          @project.write("lib/image.rb", <<~RB)
            require "smart_properties"

            class Image
              include SmartProperties

              property :title, accepts: String
              property :src, accepts: String
            end
          RB

          result = @project.tapioca("dsl --workers 3")

          assert_empty_stderr(result)
          assert_success_status(result)

          assert_project_file_exist("sorbet/rbi/dsl/post.rbi")
          assert_project_file_exist("sorbet/rbi/dsl/job.rbi")
          assert_project_file_exist("sorbet/rbi/dsl/image.rbi")
        end
      end

      describe "verify" do
        before(:all) do
          @project.require_real_gem("smart_properties", "1.15.0")
          @project.require_real_gem("sidekiq", "6.2.1")
          @project.bundle_install

          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          @project.write("lib/job.rb", <<~RB)
            require "sidekiq"

            class Job
              include Sidekiq::Worker
              def perform(foo, bar)
              end
            end
          RB
        end

        after do
          @project.remove("sorbet/rbi/dsl")
        end

        it "does nothing and returns exit status 0 with no changes" do
          @project.tapioca("dsl")
          result = @project.tapioca("dsl --verify")

          assert_includes(result.out, <<~OUT)
            Nothing to do, all RBIs are up-to-date.
          OUT

          assert_empty_stderr(result)
          assert_success_status(result)
        end

        it "advises of removed file(s) and returns exit status 1 when files are excluded" do
          @project.tapioca("dsl")
          result = @project.tapioca("dsl --verify --exclude SmartProperties")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Checking for out-of-date RBIs...


            RBI files are out-of-date. In your development environment, please run:
              `bin/tapioca dsl`
            Once it is complete, be sure to commit and push any changes

            Reason:
              File(s) removed:
              - sorbet/rbi/dsl/post.rbi
          OUT

          assert_empty_stderr(result) # FIXME: Shouldn't the errors be printed here?
          refute_success_status(result)
        end

        it "advises of new file(s) and returns exit status 1 with new files" do
          @project.tapioca("dsl")

          @project.write("lib/image.rb", <<~RB)
            require "smart_properties"

            class Image
              include(SmartProperties)

              property :title, accepts: String
            end
          RB

          result = @project.tapioca("dsl --verify")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Checking for out-of-date RBIs...


            RBI files are out-of-date. In your development environment, please run:
              `bin/tapioca dsl`
            Once it is complete, be sure to commit and push any changes

            Reason:
              File(s) added:
              - sorbet/rbi/dsl/image.rbi
          OUT

          assert_empty_stderr(result) # FIXME: Shouldn't the errors be printed here?
          refute_success_status(result)

          @project.remove("lib/image.rb")
        end

        it "advises of modified file(s) and returns exit status 1 with modified file" do
          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
            end
          RB

          @project.tapioca("dsl")

          @project.write("lib/post.rb", <<~RB)
            require "smart_properties"

            class Post
              include SmartProperties
              property :title, accepts: String
              property :desc, accepts: String
            end
          RB

          result = @project.tapioca("dsl --verify")

          assert_equal(<<~OUT, result.out)
            Loading Rails application... Done
            Loading DSL compiler classes... Done
            Checking for out-of-date RBIs...


            RBI files are out-of-date. In your development environment, please run:
              `bin/tapioca dsl`
            Once it is complete, be sure to commit and push any changes

            Reason:
              File(s) changed:
              - sorbet/rbi/dsl/post.rbi
          OUT

          assert_empty_stderr(result) # FIXME: Shouldn't the errors be printed here?
          refute_success_status(result)
        end
      end
    end
  end
end
