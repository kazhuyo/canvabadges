require File.dirname(__FILE__) + '/spec_helper'
require 'ostruct'

describe 'Badging OAuth' do
  include Rack::Test::Methods
  
  def app
    Canvabadges
  end
  
  describe "POST badge_check" do
    it "should fail when missing org config" do
      IMS::LTI::ToolProvider.any_instance.stub(:valid_request?).and_return(false)
      post "/placement_launch", {}
      last_response.should_not be_ok
      assert_error_page("Domain not properly configured.")
    end
    

    it "should fail on invalid signature" do
      example_org
      IMS::LTI::ToolProvider.any_instance.stub(:valid_request?).and_return(false)
      post "/placement_launch", {}
      last_response.should_not be_ok
      assert_error_page("Invalid tool launch - unknown tool consumer")
    end
    
    it "should succeed on valid signature" do
      example_org
      ExternalConfig.create(:config_type => 'lti', :value => '123')
      ExternalConfig.create(:config_type => 'canvas_oauth', :value => '456')
      IMS::LTI::ToolProvider.any_instance.stub(:valid_request?).and_return(true)
      IMS::LTI::ToolProvider.any_instance.stub(:roles).and_return(['student'])
      post "/placement_launch", {'oauth_consumer_key' => '123', 'lis_person_contact_email_primary' => 'bob@example.com'}
      last_response.should_not be_ok
      assert_error_page("Course must be a Canvas course, and launched with public permission settings")

      post "/placement_launch", {'oauth_consumer_key' => '123', 'tool_consumer_instance_guid' => 'something.bob.com', 'custom_canvas_user_id' => '1', 'custom_canvas_course_id' => '1', 'resource_link_id' => 'q2w3e4', 'lis_person_contact_email_primary' => 'bob@example.com'}
      last_response.should be_redirect
      bc = BadgeConfig.last
      bc.placement_id.should == 'q2w3e4'
      bc.course_id.should == '1'
      bc.domain_id.should == @domain.id
    end
    
    it "should set session parameters" do
      example_org
      ExternalConfig.create(:config_type => 'lti', :value => '123')
      ExternalConfig.create(:config_type => 'canvas_oauth', :value => '456')
      IMS::LTI::ToolProvider.any_instance.stub(:valid_request?).and_return(true)
      IMS::LTI::ToolProvider.any_instance.stub(:roles).and_return(['student'])
      post "/placement_launch", {'oauth_consumer_key' => '123', 'tool_consumer_instance_guid' => 'something.bob.com', 'custom_canvas_user_id' => '1', 'custom_canvas_course_id' => '1', 'lis_person_contact_email_primary' => 'bob@example.com'}
      last_response.should be_redirect
      session['user_id'].should == '1'
      session['launch_course_id'].should == '1'
      session['permission_for_1'].should == 'view'
      session['email'].should == 'bob@example.com'
      session['source_id'].should == 'cloud'
      session['name'].should == nil
      session['domain_id'].should == @domain.id.to_s
    end
    
    it "should provision domain if new" do
      example_org
      ExternalConfig.create(:config_type => 'lti', :value => '123')
      ExternalConfig.create(:config_type => 'canvas_oauth', :value => '456')
      IMS::LTI::ToolProvider.any_instance.stub(:valid_request?).and_return(true)
      IMS::LTI::ToolProvider.any_instance.stub(:roles).and_return(['student'])
      Domain.last.host.should_not == 'bob.org'
      post "/placement_launch", {'oauth_consumer_key' => '123', 'tool_consumer_instance_guid' => 'something.bob.org', 'custom_canvas_user_id' => '1', 'custom_canvas_course_id' => '1', 'lis_person_contact_email_primary' => 'bob@example.com'}
      last_response.should be_redirect
      Domain.last.host.should == 'bob.org'
    end
    
    it "should tie badge config to the current organization" do
      example_org
      ExternalConfig.create(:config_type => 'lti', :value => '123')
      ExternalConfig.create(:config_type => 'canvas_oauth', :value => '456')
      IMS::LTI::ToolProvider.any_instance.stub(:valid_request?).and_return(true)
      IMS::LTI::ToolProvider.any_instance.stub(:roles).and_return(['student'])
      Domain.last.host.should_not == 'bob.org'
      post "/placement_launch", {'oauth_consumer_key' => '123', 'tool_consumer_instance_guid' => 'something.bob.org', 'custom_canvas_user_id' => '1', 'custom_canvas_course_id' => '1', 'lis_person_contact_email_primary' => 'bob@example.com'}
      last_response.should be_redirect
      BadgeConfig.last.organization_id.should == @org.id
    end
    
    it "should tie badge config to a different organization if specified" do
      example_org
      ExternalConfig.create(:config_type => 'lti', :value => '123')
      ExternalConfig.create(:config_type => 'canvas_oauth', :value => '456')
      IMS::LTI::ToolProvider.any_instance.stub(:valid_request?).and_return(true)
      IMS::LTI::ToolProvider.any_instance.stub(:roles).and_return(['student'])
      post "/placement_launch", {'oauth_consumer_key' => '123', 'tool_consumer_instance_guid' => 'something.bob.org', 'custom_canvas_user_id' => '1', 'custom_canvas_course_id' => '1', 'lis_person_contact_email_primary' => 'bob@example.com'}
      last_response.should be_redirect
      BadgeConfig.last.organization_id.should == @org.id
    end
    
    it "should redirect to oauth if not authorized" do
      example_org
      @org2 = Organization.create(:host => "bob.com", :settings => {'name' => 'my org'})
      ExternalConfig.create(:config_type => 'lti', :value => '123', :organization_id => @org2.id)
      ExternalConfig.create(:config_type => 'canvas_oauth', :value => '456')
      IMS::LTI::ToolProvider.any_instance.stub(:valid_request?).and_return(true)
      IMS::LTI::ToolProvider.any_instance.stub(:roles).and_return(['student'])
      post "/placement_launch", {'oauth_consumer_key' => '123', 'tool_consumer_instance_guid' => 'something.bob.com', 'custom_canvas_user_id' => '1', 'custom_canvas_course_id' => '1', 'lis_person_contact_email_primary' => 'bob@example.com'}
      last_response.should be_redirect
      BadgeConfig.last.organization_id.should == @org2.id
    end
    
    it "should redirect to badge page if authorized" do
      example_org
      ExternalConfig.create(:config_type => 'lti', :value => '123')
      ExternalConfig.create(:config_type => 'canvas_oauth', :value => '456')
      user
      IMS::LTI::ToolProvider.any_instance.stub(:valid_request?).and_return(true)
      IMS::LTI::ToolProvider.any_instance.stub(:roles).and_return(['student'])
      post "/placement_launch", {'oauth_consumer_key' => '123', 'tool_consumer_instance_guid' => 'something.bob.com', 'resource_link_id' => '2s3d', 'custom_canvas_user_id' => @user.user_id, 'custom_canvas_course_id' => '1', 'lis_person_contact_email_primary' => 'bob@example.com'}
      last_response.should be_redirect
      bc = BadgeConfig.last
      last_response.location.should == "http://example.org/badges/check/#{bc.id}/#{@user.user_id}"
    end
    
  end  
  
  describe "GET oauth_success" do
    it "should error if session details are not preserved" do
      get "/oauth_success"
      assert_error_page("Launch parameters lost")
    end
      
    it "should error if token cannot be properly exchanged" do
      user
      fake_response = OpenStruct.new(:body => {}.to_json)
      Net::HTTP.any_instance.should_receive(:request).and_return(fake_response)
      get "/oauth_success?code=asdfjkl", {}, 'rack.session' => {"domain_id" => @domain.id, 'user_id' => @user.user_id, 'source_id' => 'cloud', 'launch_badge_config_id' => 'uiop'}
      assert_error_page("Error retrieving access token")
    end
    
    it "should provision a new user if successful" do
      fake_response = OpenStruct.new(:body => {:access_token => '1234', 'user' => {'id' => 'zxcv'}}.to_json)
      Net::HTTP.any_instance.should_receive(:request).and_return(fake_response)
      get "/oauth_success?code=asdfjkl", {}, 'rack.session' => {"domain_id" => @domain.id, 'user_id' => 'fghj', 'source_id' => 'cloud', 'launch_badge_config_id' => 'uiop'}
      @user = UserConfig.last
      @user.should_not be_nil
      @user.user_id.should == 'fghj'
      @user.domain_id.should == @domain.id
      @user.access_token.should == '1234'
      session['user_id'].should == @user.user_id
      session['domain_id'].should == @domain.id
    end
    
    it "should update an existing user if successful" do
      user
      fake_response = OpenStruct.new(:body => {:access_token => '1234', 'user' => {'id' => 'zxcv'}}.to_json)
      Net::HTTP.any_instance.should_receive(:request).and_return(fake_response)
      get "/oauth_success?code=asdfjkl", {}, 'rack.session' => {"domain_id" => @domain.id, 'user_id' => @user.user_id, 'source_id' => 'cloud', 'launch_badge_config_id' => 'uiop'}
      @new_user = UserConfig.last
      @new_user.should_not be_nil
      @new_user.id.should == @user.id
      session['user_id'].should == @user.user_id
      session['domain_id'].should == @domain.id
    end
    
    it "should redirect to the badge check endpoint if successful" do
      fake_response = OpenStruct.new(:body => {:access_token => '1234', 'user' => {'id' => 'zxcv'}}.to_json)
      Net::HTTP.any_instance.should_receive(:request).and_return(fake_response)
      get "/oauth_success?code=asdfjkl", {}, 'rack.session' => {"domain_id" => @domain.id, 'user_id' => 'fghj', 'source_id' => 'cloud', 'launch_badge_config_id' => 'uiop'}
      @user = UserConfig.last
      @user.user_id.should == 'fghj'
      @user.domain_id.should == @domain.id
      @user.access_token.should == '1234'
      session['user_id'].should == @user.user_id
      session['domain_id'].should == @domain.id
      last_response.should be_redirect
      last_response.location.should == "http://example.org/badges/check/uiop/#{@user.user_id}"
    end
  end  
end
