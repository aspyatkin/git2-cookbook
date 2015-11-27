require 'chef/resource'

class Chef
  class Resource
    class Git2 < Chef::Resource
      def initialize(name, run_context=nil)
        super
        @resource_name = :git2
        @provider = Chef::Provider::Git2
        @action = :create
        @allowed_actions = [:create]

        @url = nil
        @branch = 'master'
        @target = name
        @user = 'root'
        @group = 'root'
      end

      def url(arg=nil)
        set_or_return(:url, arg, :kind_of => String)
      end

      def branch(arg=nil)
        set_or_return(:branch, arg, :kind_of => String)
      end

      def target(arg=nil)
        set_or_return(:target, arg, :kind_of => String)
      end

      def user(arg=nil)
        set_or_return(:user, arg, :kind_of => String)
      end

      def group(arg=nil)
        set_or_return(:group, arg, :kind_of => String)
      end
    end
  end
end
