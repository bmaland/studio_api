require "studio_api/studio_resource"
require "studio_api/generic_request"
require "studio_api/pattern"
require "studio_api/package"
require "xmlsimple"
require "fileutils"

module StudioApi
  # Represents appliance in studio
  # beside information about itself contains also information about its 
  # relative object like packages, signing keys etc
  # Each method try to be ActiveResource compatible, so each can throw ConnectionError
  class Appliance < ActiveResource::Base
    extend StudioResource

    self.element_name = "appliance"

    # Represents status of appliance
    # used as output for Appliance#status
    # @see Appliance#status
    class Status < ActiveResource::Base
      extend StudioResource
    end

    # Represents repository assigned to appliance
    class Repository < ActiveResource::Base
      extend StudioResource
      self.prefix = "/appliances/:appliance_id/"
      self.element_name = "repository"
      mattr_accessor :appliance

      #for delete repository doesn't work clasic method from ARes
      def destroy
        self.class.appliance.remove_repository id
      end

      #for delete repository doesn't work clasic method from ARes
      def self.delete (id, options)
        my_app = Appliance.dup
        my_app.studio_connection = studio_connection
        my_app.new(:id => options[:appliance_id]).remove_repository id
      end
    end
    
    # Represents GPGKey assigned to appliance
    class GpgKey < ActiveResource::Base
      extend StudioResource
      self.prefix = "/appliances/:appliance_id/"
      self.element_name = "gpg_key"
      mattr_accessor :appliance

      # upload new GPG key to appliance
      # @param (#to_i) appliance_id id of appliance to which load gpg key
      # @param (#to_s) name of gpg key
      # @param (File, String) opened file containing key or key in string
      # @param (Hash) options additional options keys as it allow studio API
      # @example Load from file
      #   File.open ("/etc/my.cert") do |file|
      #     StudioApi::Appliance::GpgKey.create 1234, "my new cool key", file, :target => "rpm"
      #   end
      def self.create (appliance_id, name, key, options={})
        options[:target] ||= "rpm"
        if key.is_a? String #if key is string, that pass it in request, if not pack it in body
          options[:key] = key
        end
        request_str = "/appliances/#{appliance_id.to_i}/gpg_keys?name=#{name}"
        options.each do |k,v|
          request_str << "&#{URI.escape k.to_s}=#{URI.escape v.to_s}"
        end
        GenericRequest.new(studio_connection).post request_str, :key => key
      end
    end

    # gets status of appliance
    # @return [StudioApi::Appliance::Status] resource of status
    def status
      Status.studio_connection = self.class.studio_connection
      #rails is so smart, that it ignores prefix for calls. At least it is good that we don't want to do such things from library users
      from = Util.join_relative_url( self.class.site.path,"appliances/#{id.to_i}/status")
      Status.find :one, :from => from
    end

    # Gets all repositories assigned to appliance
    # @return [StudioApi::Appliance::Repository] assigned repositories
    def repositories
      my_repo = Repository.dup
      my_repo.studio_connection = self.class.studio_connection
      my_repo.appliance = self
      my_repo.find :all, :params => { :appliance_id => id }
    end

    # remove repositories from appliance
    # @param (#to_s,Array<#to_s>)
    # @example various way to remove repo
    #   appl = Appliance.find 1234
    #   appl.remove_repository 5678
    #   appl.remove_repository [5678,34,56,78,90]
    #   appl.remove_repository 5678,34,56,78,90
    def remove_repository (*repo_ids)
      repo_ids.flatten.each do |repo_id|
        post "#{id}/cmd/remove_repository", :repo_id => repo_id
      end
    end

    # adds repositories to appliance
    # @param (#to_s,Array<#to_s>)
    # @example various way to add repo
    #   appl = Appliance.find 1234
    #   appl.add_repository 5678
    #   appl.add_repository [5678,34,56,78,90]
    #   appl.add_repository 5678,34,56,78,90
    def add_repository (*repo_ids)
      repo_ids.flatten.each do |repo_id|
        post "#{id}/cmd/add_repository", :repo_id => repo_id
      end
    end

    # adds repository for user rpms
    def add_user_repository
      post "#{id}/cmd/add_user_repository"
    end

    # clones appliance or template
    # @see (StudioApi::TemplateSet)
    # @param (#to_i) source_id id of source appliance
    # @param (Hash<String,String>) options optional parameters to clone command
    # @return (StudioApi::Appliance) resulted appliance
    def self.clone source_id,options={}
      options[:appliance_id] = source_id.to_i
      request_str = "/appliances?clone_from=#{source_id.to_i}"
      options.each do |k,v|
        request_str << "&#{URI.escape k.to_s}=#{URI.escape v.to_s}"
      end
      response = GenericRequest.new(studio_connection).post request_str, options
      Appliance.new Hash.from_xml(response)["appliance"]
    end

    # Gets all GPG keys assigned to appliance
    # @return [Array<StudioApi::Appliance::GpgKey>] included keys
    def gpg_keys
      my_key = GpgKey.dup
      my_key.studio_connection = self.class.studio_connection
      my_key.find :all, :params => { :appliance_id => id }
    end

    # Gets GPG key assigned to appliance with specified id
    # @param (#to_s) key_id id of requested key
    # @return [StudioApi::Appliance::GpgKey,nil] found key or nil if it is not found
    def gpg_key( key_id )
      my_key = GpgKey.dup
      my_key.studio_connection = self.class.studio_connection
      my_key.find key_id, :params => { :appliance_id => id }
    end

    # add GPG key to appliance
    # @params (see GpgKey#create)
    def add_gpg_key (name, key, options={})
      my_key = GpgKey.dup
      my_key.studio_connection = self.class.studio_connection
      my_key.create id, name, key, options
    end

    # Gets list of all explicitelly selected software ( package and patterns)
    # in appliance
    # @return (Array<StudioApi::Package,StudioApi::Pattern>) list of selected packages and patterns
    def selected_software
      request_str = "/appliances/#{id.to_i}/software"
      response = GenericRequest.new(self.class.studio_connection).get request_str
      attrs = XmlSimple.xml_in response
      convert_selectable attrs
    end

    # Gets list of all installed (include dependencies) software
    # (package and patterns) in appliance
    # @param (#to_i) build_id specifies ID of build, otherwise use the latest one
    # @return (Array<StudioApi::Package,StudioApi::Pattern>) list of installed packages and patterns
    def installed_software (build_id = nil)
      request_str = "/appliances/#{id.to_i}/software/installed"
			request_str << "?build_id=#{build_id.to_i}" if build_id
      response = GenericRequest.new(self.class.studio_connection).get request_str
      attrs = XmlSimple.xml_in response
			res = []
			attrs["repository"].each do |repo|
				options = { "repository_id" => repo["id"].to_i }
      	res += convert_selectable repo["software"][0], options
			end
			res
    end

    # Search software (package and patterns) in appliance
    # @param (#to_s) search_string string which is used for search
    # @param (Hash<#to_s,#to_s>) options optional parameters for search, see api documentation
    # @return (Array<StudioApi::Package,StudioApi::Pattern>) list of installed packages and patterns
    def search_software (search_string,options={})
      request_str = "/appliances/#{id.to_i}/software/search?q=#{URI.escape search_string.to_s}"
			options.each do |k,v|
				request_str << "&#{URI.escape k.to_s}=#{URI.escape v.to_s}"
			end
      response = GenericRequest.new(self.class.studio_connection).get request_str
      attrs = XmlSimple.xml_in response
			res = []
			attrs["repository"].each do |repo|
				options = { "repository_id" => repo["id"].to_i }
      	res += convert_selectable repo["software"][0], options
			end
			res
    end

    # Select new package to be installed in appliance.
    #
    # Dependencies is automatic resolved, but its repository have to be already
    # included in appliance
		# @param(#to_s) name of package
    # @param (Hash<#to_s,#to_s>) options optional parameters for search, see api documentation
		def add_package (name, options={})
			appliance_command "add_package",{:name => name}.merge(options)
		end

    # Deselect package from appliance.
    #
    # Dependencies is automatic resolved (so unneeded dependencies not installed),
    # but unused repositories is kept
		# @param(#to_s) name of package
		def remove_package (name)
			appliance_command "remove_package",:name => name
		end

    # Select new pattern to be installed in appliance.
    #
    # Dependencies is automatic resolved, but its repositories have to be already
    # included in appliance
		# @param(#to_s) name of pattern
    # @param (Hash<#to_s,#to_s>) options optional parameters for search, see api documentation
		def add_pattern (name, options={})
			appliance_command "add_pattern",{:name => name}.merge(options)
		end

    # Deselect pattern from appliance.
    #
    # Dependencies is automatic resolved (so unneeded dependencies not installed),
    # but unused repositories is kept
		# @param(#to_s) name of pattern
		def remove_pattern (name)
			appliance_command "remove_pattern",:name => name
		end

    # Bans package ( so it cannot be installed even as dependency).
		# @param(#to_s) name of package
		def ban_package(name)
			appliance_command "ban_package",:name => name
		end

    # Unbans package ( so then it can be installed).
		# @param(#to_s) name of package
		def unban_package(name)
			appliance_command "unban_package",:name => name
		end

private
#internal overwrite of ActiveResource::Base methods
    def new?
      false #Appliance has only POST method
    end

#studio post method for clone is special, as it sometime doesn't have element inside
    def custom_method_element_url(method_name,options = {})
      prefix_options, query_options = split_options(options)
      method_string = method_name.blank? ? "" : "/#{method_name}"
      "#{self.class.prefix(prefix_options)}#{self.class.collection_name}#{method_string}#{self.class.send :query_string,query_options}"
    end
    def self.custom_method_collection_url(method_name,options = {})
      prefix_options, query_options = split_options(options)
      "#{prefix(prefix_options)}#{collection_name}#{query_string query_options}"
    end

    def convert_selectable attrs, preset_options = {}
      res = []
      (attrs["pattern"]||[]).each do |pattern|
        res << create_model_based_on_attrs(Pattern, pattern, preset_options)
      end
      (attrs["package"]||[]).each do |package|
        res << create_model_based_on_attrs( Package, package, preset_options)
      end
      res
    end

#generic factory to create model based on attrs which can be string of hash of options + content which is same as string
    def create_model_based_on_attrs model, attrs, preset_options
      case attrs
      when Hash
          name = attrs.delete "content"
          model.new(name, preset_options.merge(attrs))
      when String
          model.new(attrs)
      else
          raise "Unknown format of element #{model}"
      end
    end

		def appliance_command type, options={}
      request_str = "/appliances/#{id.to_i}/cmd/#{type}"
			unless options.empty?
				first = true
				options.each do |k,v|
					separator = first ? "?" : "&"
					first = false
					request_str << "#{separator}#{URI.escape k.to_s}=#{URI.escape v.to_s}"
				end
			end
      GenericRequest.new(self.class.studio_connection).post request_str, options
		end
  end
end
