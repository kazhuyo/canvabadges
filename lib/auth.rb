require 'sinatra/base'

module Sinatra
  module Auth
    def self.registered(app)
      app.helpers Auth::Helpers
      
      app.post "/badge_check" do
        error("This is an old launch. You need to re-configure your LTI settings")
      end
      
      # LTI tool launch, makes sure we're oauth-good and then redirects to the magic page
      app.post "/placement_launch" do
        get_org
        key = params['oauth_consumer_key']
        tool_config = ExternalConfig.first(:config_type => 'lti', :value => key)
        if !tool_config
          halt 400, error("Invalid tool launch - unknown tool consumer")
        end
        secret = tool_config.shared_secret
        host = params['custom_canvas_api_domain']
        if host && params['launch_presentation_return_url'].match(Regexp.new(host.sub(/\.instructure\.com/, ".(test|beta).instructure.com")))
          host = params['launch_presentation_return_url'].split(/\//)[2]
        end
        host ||= params['tool_consumer_instance_guid'].split(/\./)[1..-1].join(".") if params['tool_consumer_instance_guid'] && params['tool_consumer_instance_guid'].match(/\./)
        domain = Domain.first_or_new(:host => host)
        domain.name = params['tool_consumer_instance_name']
        domain.save
        provider = IMS::LTI::ToolProvider.new(key, secret, params)
        if !params['custom_canvas_user_id'] || !params['custom_canvas_course_id']
          halt 400, error("This app appears to have been misconfigured, please contact your instructor or administrator. Course must be a Canvas course, and launched with public permission settings")
        end
        if !params['lis_person_contact_email_primary']
          halt 400, error("This app appears to have been misconfigured, please contact your instructor or administrator. Email address is required on user launches.")
        end
        if provider.valid_request?(request)
          bc = BadgeConfig.first_or_new(:placement_id => params['resource_link_id'], :domain_id => domain.id, :course_id => params['custom_canvas_course_id'])
          bc.external_config_id ||= tool_config.id
          bc.organization_id = tool_config.organization_id if !bc.id
          bc.organization_id ||= @org.id
          bc.settings ||= {}
          bc.settings['course_url'] ||= "#{BadgeHelper.protocol}://" + host + "/courses/" + params['custom_canvas_course_id']
          bc.save
          user_id = params['custom_canvas_user_id']
          user_config = UserConfig.first(:user_id => user_id, :domain_id => domain.id)
          session["user_id"] = user_id
          session["user_image"] = params['user_image']
          session["launch_placement_id"] = params['resource_link_id']
          session["launch_badge_config_id"] = bc.id
          session["launch_course_id"] = params['custom_canvas_course_id']
          session["permission_for_#{params['custom_canvas_course_id']}"] = 'view'
          session['email'] = params['lis_person_contact_email_primary']
          # TODO: something akin to this parameter needs to be sent in order to
          # tell the difference between Canvas Cloud and Canvas CV instances.
          # Otherwise I can't tell the difference between global_user_id 5 from
          # Cloud as opposed to from CV.
          session['source_id'] = params['custom_canvas_system_id'] || 'cloud'
          session['name'] = params['lis_person_name_full']
          # check if they're a teacher or not
          session["permission_for_#{params['custom_canvas_course_id']}"] = 'edit' if provider.roles.include?('instructor') || provider.roles.include?('contentdeveloper') || provider.roles.include?('urn:lti:instrole:ims/lis/administrator') || provider.roles.include?('administrator')
          session['domain_id'] = domain.id.to_s
          # if we already have an oauth token then we're good
          if user_config
            user_config.image = params['user_image']
            user_config.save
            session['user_id'] = user_config.user_id

            if params['custom_show_all']
              redirect to("/badges/all/#{user_config.user_id}")
            else
              redirect to("/badges/check/#{bc.id}/#{user_config.user_id}")
            end
          # otherwise we need to do the oauth dance for this user
          else
            oauth_dance(request, host)
          end
        else
          return error("Invalid tool launch - invalid parameters")
        end
      end
  
      app.get "/oauth_success" do
        if !session['domain_id'] || !session['user_id'] || !session['launch_badge_config_id'] || !session['source_id']
          return error("Launch parameters lost")
        end
        domain = Domain.first(:id => session['domain_id'])
        return_url = "#{protocol}://#{request.host_with_port}/oauth_success"
        code = params['code']
        url = "#{protocol}://#{domain.host}/login/oauth2/token"
        uri = URI.parse(url)
        
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = protocol == "https"
        request = Net::HTTP::Post.new(uri.request_uri)
        request.set_form_data({
          :client_id => oauth_config.value,
          :code => code,
          :client_secret => oauth_config.shared_secret,
          :redirect_uri => CGI.escape(return_url)
        })
        response = http.request(request)
        json = JSON.parse(response.body)
        
        if json && json['access_token']
          user_config = UserConfig.first(:user_id => session['user_id'], :domain_id => domain.id)
          user_config ||= UserConfig.new(:user_id => session['user_id'], :domain_id => domain.id)
          user_config.access_token = json['access_token']
          user_config.name = session['name']
          user_config.image = session['user_image']
          user_config.global_user_id = session['source_id'] + "_" + json['user']['id'].to_s
          user_config.save
          redirect to("/badges/check/#{session['launch_badge_config_id']}/#{user_config.user_id}")
          session.destroy
          session['user_id'] = user_config.user_id.to_s
          session['domain_id'] = user_config.domain_id.to_s
        else
          return error("Error retrieving access token")
        end
      end
      
      app.get "/login" do
        request_token = consumer.get_request_token(:oauth_callback => "#{request.scheme}://#{request.host_with_port}/login_success")
        if request_token.token && request_token.secret
          session[:oauth_token] = request_token.token
          session[:oauth_token_secret] = request_token.secret
        else
          return "Authorization failed"
        end
        redirect to("https://api.twitter.com/oauth/authenticate?oauth_token=#{request_token.token}")
      end
      
      app.get "/login_success" do
        verifier = params[:oauth_verifier]
        if params[:oauth_token] != session[:oauth_token]
          return "Authorization failed"
        end
        request_token = OAuth::RequestToken.new(consumer,
          session[:oauth_token],
          session[:oauth_token_secret]
        )
        access_token = request_token.get_access_token(:oauth_verifier => verifier)
        screen_name = access_token.params['screen_name']
        
        if !screen_name
          return "Authorization failed"
        end
        
        
        @org = Organization.first(:host => request.env['HTTP_HOST'])
        @conf = ExternalConfig.generate(screen_name)
        erb :config_tokens
      end
    end
    module Helpers
      def consumer
        consumer ||= OAuth::Consumer.new(twitter_config.value, twitter_config.shared_secret, {
          :site => "http://api.twitter.com",
          :request_token_path => "/oauth/request_token",
          :access_token_path => "/oauth/access_token",
          :authorize_path=> "/oauth/authorize",
          :signature_method => "HMAC-SHA1"
        })
      end
      
      def twitter_config
        @@twitter_config ||= ExternalConfig.first(:config_type => 'twitter_for_login')
      end
    end
  end
  
  register OAuth
end
