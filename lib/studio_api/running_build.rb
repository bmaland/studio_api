require "studio_api/studio_resource"

require "cgi"

module StudioApi
  # Represents running build in studio.
  #
  # Provide finding builds, canceling build process or running new build
  # For parameters see API documentation
  # @example Run new build and then cancel it
  #   rb = StudioApi::RunningBuild.new(:appliance_id => 1234, :force => "true", :multi => "true")
  #   rb.save!
  #   sleep 5
  #   rb.cancel
  #
  # An ImageAlreadyExists exception is raised when force parameter is not
  # specified and there's already a build with the same version.
  class RunningBuild < ActiveResource::Base
    extend StudioResource

    self.element_name = "running_build"

    alias_method :cancel, :destroy

private
    #overwrite create as studio doesn't interact well with enclosed parameters
    def create
      request_str = collection_path
      request_str << "?appliance_id=#{attributes.delete("appliance_id").to_i}"
      attributes.each do |k,v|
        request_str << "&#{CGI.escape k.to_s}=#{CGI.escape v.to_s}"
      end
      connection.post(request_str,"",self.class.headers).tap do |response|
        load_attributes_from_response response
      end
    rescue ActiveResource::BadRequest => e
      tree = XmlSimple.xml_in(e.response.body)
      code = tree["code"][0]
      if code == "image_already_exists"
        message = tree["message"][0]
        raise ImageAlreadyExists.new message
      else
        raise e
      end
    end
  end

  class ImageAlreadyExists < StandardError
  end
end
