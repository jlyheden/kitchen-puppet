# -*- encoding: utf-8 -*-
#
# Author:: Chris Lundquist (<chris.lundquist@github.com>) Neill Turner (<neillwturner@gmail.com>)
#
# Copyright (C) 2013,2014 Chris Lundquist, Neill Turner
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'kitchen/provisioner/base'
require 'kitchen/provisioner/puppet/librarian'

module Kitchen

  module Provisioner

    # Puppet Apply provisioner.
    #
    class PuppetApply < Base
      attr_accessor :tmp_dir

      default_config :require_puppet_omnibus, false
      # TODO use something like https://github.com/fnichol/omnibus-puppet
      default_config :puppet_omnibus_url, nil
      default_config :puppet_version, nil
      default_config :puppet_apt_repo, "http://apt.puppetlabs.com/puppetlabs-release-precise.deb"
	  default_config :puppet_yum_repo, "https://yum.puppetlabs.com/puppetlabs-release-el-6.noarch.rpm"

      default_config :manifest, 'site.pp'

      default_config :manifests_path do |provisioner|
        provisioner.calculate_path('manifests') or
          raise 'No manifests_path detected. Please specify one in .kitchen.yml'
      end

      default_config :modules_path do |provisioner|
        provisioner.calculate_path('modules') or
          raise 'No modules_path detected. Please specify one in .kitchen.yml'
      end

      default_config :hiera_data_path do |provisioner|
        provisioner.calculate_path('hiera')
      end

      default_config :hiera_config_path do |provisioner|
        provisioner.calculate_path('hiera.yaml', :file)
      end

      default_config :puppet_debug, false
      default_config :puppet_verbose, false
      default_config :puppet_noop, false
	  default_config :puppet_platform, 'ubuntu'
      default_config :update_packages, true
	  default_config :custom_facts, {}

      def install_command
        info('installing puppet')
        case puppet_platform
        when "debian", "ubuntu"
          <<-INSTALL
          if [ ! $(which puppet) ]; then
            #{sudo('wget')} #{puppet_apt_repo}
            #{sudo('dpkg')} -i #{puppet_apt_repo_file}
            #{update_packages_debian_cmd}
            #{sudo('apt-get')} -y install puppet#{puppet_version}
          fi
         INSTALL
		when "redhat", "centos", "fedora"
          <<-INSTALL		
          if [ ! $(which puppet) ]; then
            #{sudo('rpm')} -ivh #{puppet_yum_repo}
 		    #{update_packages_redhat_cmd}           
            #{sudo('yum')} -y install puppet#{puppet_version}
          fi
         INSTALL
         end		
     end

        def init_command
          dirs = %w{modules manifests hiera hiera.yaml}.
            map { |dir| File.join(config[:root_path], dir) }.join(" ")
          cmd = "#{sudo('rm')} -rf #{dirs} /var/lib/hiera /etc/hiera.yaml /etc/puppet/hiera.yaml; mkdir -p #{config[:root_path]}"
          debug(cmd)
          cmd
        end

        def create_sandbox
          super
          debug("Creating local sandbox in #{sandbox_path}")

          yield if block_given?

          prepare_modules
          prepare_manifests
          prepare_hiera_config
          prepare_hiera_data
          info('Finished Preparing files for transfer')

        end

        def cleanup_sandbox
          return if sandbox_path.nil?
          debug("Cleaning up local sandbox in #{sandbox_path}")
          FileUtils.rmtree(sandbox_path)
        end

        def prepare_command
          commands = []

          if hiera_config
            commands << [
              sudo('cp'), File.join(config[:root_path],'hiera.yaml'), '/etc/',
            ].join(' ')

            commands << [
              sudo('cp'), File.join(config[:root_path],'hiera.yaml'), '/etc/puppet/',
            ].join(' ')
          end

          if hiera_data
            commands << [
              sudo('cp -r'), File.join(config[:root_path], 'hiera'), '/var/lib/'
            ].join(' ')
          end
          command = commands.join(' && ')
          debug(command)
          command
        end

        def run_command
          [
            custom_facts,
            sudo('puppet'),
            'apply',
            File.join(config[:root_path], 'manifests', manifest),
            "--modulepath=#{File.join(config[:root_path], 'modules')}",
            "--manifestdir=#{File.join(config[:root_path], 'manifests')}",
            puppet_noop_flag,
            puppet_verbose_flag,
            puppet_debug_flag,
          ].join(" ")
        end

        protected

        def load_needed_dependencies!
          if File.exists?(puppetfile)
            debug("Puppetfile found at #{puppetfile}, loading Librarian-Puppet")
            Puppet::Librarian.load!(logger)
          end
        end

        def tmpmodules_dir
          File.join(sandbox_path, 'modules')
        end

        def puppetfile
          File.join(config[:kitchen_root], 'Puppetfile')
        end

        def manifest
          config[:manifest]
        end

        def manifests
          config[:manifests_path]
        end

        def modules
          config[:modules_path]
        end

        def hiera_config
          config[:hiera_config_path]
        end

        def hiera_data
          config[:hiera_data_path]
        end

        def puppet_version
          case puppet_platform
          when "debian", "ubuntu"
            config[:puppet_version] ? "=#{config[:puppet_version]}" : nil
 		  when "redhat", "centos", "fedora"
            config[:puppet_version] ? "-#{config[:puppet_version]}" : nil
 		  end	 
        end

        def puppet_noop_flag
          config[:puppet_noop] ? '--noop' : nil
        end

        def puppet_debug_flag
          config[:puppet_debug] ? '-d' : nil
        end

        def puppet_verbose_flag
          config[:puppet_verbose] ? '-v' : nil
        end
		
        def puppet_platform
          config[:puppet_platform].to_s.downcase
        end		

        def update_packages_debian_cmd
          config[:update_packages] ? "#{sudo('apt-get')} -y update" : nil  
        end
		
		def update_packages_redhat_cmd
          config[:update_packages] ? "#{sudo('yum')} -y update" : nil
 		end

        def custom_facts
          return nil if config[:custom_facts].none?
          bash_vars = config[:custom_facts].map { |k,v| "FACTER_#{k}=#{v}" }.join(" ")
          bash_vars = "export #{bash_vars};"
          debug(bash_vars)
          bash_vars
        end

        def puppet_apt_repo
          config[:puppet_apt_repo]
        end

        def puppet_apt_repo_file
          config[:puppet_apt_repo].split('/').last
        end

        def puppet_yum_repo
          config[:puppet_yum_repo]
        end

        def prepare_manifests
          info('Preparing manifests')
          debug("Using manifests from #{manifests}")

          tmp_manifests_dir = File.join(sandbox_path, 'manifests')
          FileUtils.mkdir_p(tmp_manifests_dir)
          FileUtils.cp_r(Dir.glob("#{manifests}/*"), tmp_manifests_dir)
        end

        def prepare_modules
          info('Preparing modules')
          if File.exists?(puppetfile)
            resolve_with_librarian
          end
          debug("Using modules from #{modules}")

          tmp_modules_dir = File.join(sandbox_path, 'modules')
          FileUtils.mkdir_p(tmp_modules_dir)
          FileUtils.cp_r(Dir.glob("#{modules}/*"), tmp_modules_dir)
        end

        def prepare_hiera_config
          return unless hiera_config

          info('Preparing hiera')
          debug("Using hiera from #{hiera_config}")

          FileUtils.cp_r(hiera_config, File.join(sandbox_path, 'hiera.yaml'))
        end

        def prepare_hiera_data
          return unless hiera_data
          info('Preparing hiera data')
          debug("Using hiera data from #{hiera_data}")

          tmp_hiera_dir = File.join(sandbox_path, 'hiera')
          FileUtils.mkdir_p(tmp_hiera_dir)
          FileUtils.cp_r(Dir.glob("#{hiera_data}/*"), tmp_hiera_dir)
        end

        def resolve_with_librarian
          Kitchen.mutex.synchronize do
            Puppet::Librarian.new(puppetfile, tmpmodules_dir, logger).resolve
          end
        end
    end
  end
end