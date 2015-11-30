require 'chef/exceptions'
require 'chef/log'
require 'chef/provider'
require 'fileutils'

class Chef
  class Exceptions
    class Git2RuntimeError < RuntimeError; end
  end
end

class Chef
  class Provider
    class Git2 < Chef::Provider
      provides :git2

      def whyrun_supported?
        true
      end

      def load_current_resource
        @current_resource ||= Chef::Resource::Git2.new(new_resource.name)
        metadata = find_current_metadata

        if metadata.has_key? :branch
          @current_resource.branch metadata[:branch]
        end

        if metadata.has_key? :url
          @current_resource.url metadata[:url]
        end
        @current_resource
      end

      def define_resource_requirements
        requirements.assert(:create) do |a|
          dirname = ::File.dirname(@new_resource.target)
          a.assertion { ::File.directory?(dirname) }
          a.whyrun("Directory #{dirname} does not exist, this run will fail unless it has been previously created. Assuming it would have been created.")
          a.failure_message(Chef::Exceptions::MissingParentDirectory,
            "Cannot clone #{@new_resource} to #{@new_resource.target}, the enclosing directory #{dirname} does not exist")
        end

        requirements.assert(:all_actions) do |a|
          a.assertion { !(@new_resource.branch =~ /^origin\//) }
          a.failure_message Chef::Exceptions::InvalidRemoteGitReference,
             "Deploying remote branches is not supported. " +
             "Specify the remote branch as a local branch for " +
             "the git repository you're deploying from " +
             "(ie: '#{@new_resource.branch.gsub('origin/', '')}' rather than '#{@new_resource.branch}')."
        end

        requirements.assert(:create) do |a|
          if @current_resource.url
            a.assertion { @current_resource.url == @new_resource.url }
            a.whyrun("Git repository at #{new_resource.target} has different origin url. Assuming it would have matched the specified value.")
            a.failure_message(Chef::Exceptions::Git2RuntimeError,
              "Cannot clone #{@new_resource} to #{@new_resource.target}, another git repository is already located here")
          end
        end

        requirements.assert(:create) do |a|
          a.assertion { branch_exists? }
          a.whyrun("Git remote reference should be present. Assuming it would have been created.")
          a.failure_message(Chef::Exceptions::Git2RuntimeError,
            "Cannot checkout #{@new_resource} to #{@new_resource.target}, remote reference #{@new_resource.branch} does not exist")
        end
      end

      def action_create
        if target_dir_non_existent_or_empty?
          git_clone
        else
          git_fetch
          if @current_resource.branch != @new_resource.branch
            if repository_dirty?
              raise Chef::Exceptions::Git2RuntimeError, "Repository #{@new_resource} is dirty"
            else
              commits_ahead = get_commits_ahead
              if commits_ahead > 0
                raise Chef::Exceptions::Git2RuntimeError, "Local branch #{@new_resource.branch} of #{@new_resource} is #{commits_ahead} commit(s) ahead remote. Please push your changes"
              else
                git_checkout
              end
            end
          else
            unless repository_dirty?
              commits_ahead = get_commits_ahead
              commits_behind = get_commits_behind
              if commits_ahead == 0 and commits_behind > 0
                git_pull
              end
            end
          end
        end
      end

      private
      def cwd
        @new_resource.target
      end

      def find_current_metadata
        result = {}
        Chef::Log.debug("#{@new_resource} finding current git repository metadata")
        if ::File.exist?(::File.join(cwd, ".git"))
          result[:url] = shell_out!('git config --get remote.origin.url', cwd: cwd, returns: [0, 1]).stdout.strip
          result[:branch] = shell_out!('git rev-parse --abbrev-ref HEAD', cwd: cwd, returns: [0,128]).stdout.strip
        end
        result
      end

      def target_dir_non_existent_or_empty?
        !::File.exist?(@new_resource.target) || Dir.entries(@new_resource.target).sort == ['.','..']
      end

      def run_options(run_opts={})
        env = {}
        if @new_resource.user
          run_opts[:user] = @new_resource.user
          env['HOME'] = begin
            require 'etc'
            Etc.getpwnam(@new_resource.user).dir
          rescue ArgumentError # user not found
            raise Chef::Exceptions::User, "Could not determine HOME for specified user '#{@new_resource.user}' for resource '#{@new_resource.name}'"
          end
        end
        run_opts[:group] = @new_resource.group if @new_resource.group
        # env['GIT_SSH'] = @new_resource.ssh_wrapper if @new_resource.ssh_wrapper
        run_opts[:log_tag] = @new_resource.to_s
        # run_opts[:timeout] = @new_resource.timeout if @new_resource.timeout
        # env.merge!(@new_resource.environment) if @new_resource.environment
        run_opts[:environment] = env unless env.empty?
        run_opts
      end

      def git_clone
        converge_by("clone from #{@new_resource.url} into #{@new_resource.target}") do

          args = []
          args << "-b #{@new_resource.branch}" unless @new_resource.branch == 'master'

          Chef::Log.info "#{@new_resource} cloning repo #{@new_resource.url} to #{@new_resource.target}"

          command = %Q(git clone #{args.join(' ')} "#{@new_resource.url}" "#{@new_resource.target}")
          shell_out!(command, run_options)
        end
      end

      def git_fetch
        command = 'git fetch --all'
        shell_out!(command, run_options(cwd: @new_resource.target))
      end

      def git_checkout
        converge_by("checkout branch #{@new_resource.branch} on #{@new_resource.url} into #{@new_resource.target}") do
          checkout_cmd = "git checkout #{@new_resource.branch}"
          shell_out!(checkout_cmd, run_options(cwd: @new_resource.target))
        end
      end

      def git_pull
        converge_by("pull #{@new_resource.url} to #{@new_resource.target}") do
          pull_cmd = "git pull --rebase"
          shell_out!(pull_cmd, run_options(cwd: @new_resource.target))
        end
      end

      def branch_exists?
        Chef::Log.debug("#{@new_resource} resolving remote reference")
        ls_remote_command = %Q(git ls-remote "#{@new_resource.url}" "#{new_resource.branch}*")
        @resolved_reference = shell_out!(ls_remote_command, run_options).stdout
        refs = @resolved_reference.split("\n").map { |line| line.split("\t") }
        return refs.size > 0
      end

      def local_branch
        command = 'git rev-parse --abbrev-ref HEAD'
        shell_out!(command, run_options(cwd: cwd)).stdout.strip
      end

      def remote_branch
        command = 'git rev-parse --abbrev-ref --symbolic-full-name @{u}'
        shell_out!(command, run_options(cwd: cwd)).stdout.strip
      end

      def repository_dirty?
        command = 'git status --porcelain'
        output = shell_out!(command, run_options(cwd: cwd)).stdout
        return output != ''
      end

      def get_local_remote_diff_count
        command = "git rev-list --left-right --count #{local_branch}...#{remote_branch}"
        output = shell_out!(command, run_options(cwd:cwd)).stdout.strip
        output.split("\t")
      end

      def get_commits_ahead
        get_local_remote_diff_count[0].to_i
      end

      def get_commits_behind
        get_local_remote_diff_count[1].to_i
      end
    end
  end
end
