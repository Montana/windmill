require 'sinatra'
require 'sinatra/namespace'
require 'sinatra/flash'
require 'json'
require 'omniauth'
require 'omniauth-github'
require 'omniauth-heroku'
require 'omniauth-google-oauth2'
require 'securerandom'
require_relative 'lib/models/endpoint'
require_relative 'lib/models/configuration'
require_relative 'lib/models/configuration_group'
require_relative 'lib/models/enroller'

NODE_ENROLL_SECRET = ENV['NODE_ENROLL_SECRET'] || "valid_test"

use Rack::Session::Cookie, expire_after: 86_400, secret: ENV['COOKIE_SECRET'] || SecureRandom.hex(64)
use OmniAuth::Builder do
  provider :github, ENV['GITHUB_KEY'], ENV['GITHUB_SECRET'], scope: "user:email"
  provider :heroku, ENV['HEROKU_KEY'], ENV['HEROKU_SECRET'], fetch_info: true, scope: "identity"
  provider :google_oauth2, ENV['GOOGLE_ID'], ENV['GOOGLE_SECRET'], name: 'google'
end

if ENV['FULL_URL']
  OmniAuth.config.full_host = ENV['FULL_URL']
end

def logdebug(message)
  if ENV['OSQUERYDEBUG']
    puts "\n" + caller_locations(1,1)[0].label + ": " + message
  end
end

configure do
  if ENV['AUTHORIZEDUSERS']
    set :authorized_users, ENV['AUTHORIZEDUSERS'].split(',')
  else
    begin
      set :authorized_users, File.open('authorized_users.txt').readlines.map {|line| line.strip}
    rescue
      raise ArgumentError, "No ENV or file for authorized users. See: https://github.com/heroku/windmill#authentication-and-logging-in"
    end
  end
end

before do
  pass if request.path_info =~ /^\/auth\//
  pass if request.path_info =~ /^\/api\//
  pass if request.path_info =~ /^\/status/
  redirect to('/auth/login') unless current_user
end

helpers do
  def current_user
    session[:email] || nil
  end

  def bootflash
    remapper = {notice: "alert alert-info", success: "alert alert-success", warning: "alert alert-danger"}
    flash.collect {|k, v| "<div class=\"#{remapper[k]}\">#{v}</div>"}.join
  end
end

get '/status' do
  "running at #{Time.now}"
end

get '/' do
  redirect '/configuration-groups'
end

namespace '/auth' do
  get '/login' do
    erb :"auth/login", layout: :'login_layout'
  end

  get '/:provider/callback' do
    logdebug JSON.pretty_generate(request.env['omniauth.auth'])
    email = env['omniauth.auth']['info']['email']
    if settings.authorized_users.include? email
      session[:email] = email
      flash[:notice] = "#{email} logged in successfully."
      redirect to('/')
    end
    flash[:warning] = "#{email} logged in successfully but not authorized in authorized_users.txt"
    redirect to('/auth/login')
  end

  get '/failure' do
    flash[:warning] = "Authentication failed."
    redirect to('/auth/login')
    # erb "<h1>Authentication Failed:</h1><h3>message:<h3> <pre>#{params}</pre>"
  end

  get '/:provider/deauthorized' do
    erb "#{params[:provider]} has deauthorized this app."
  end

  get '/logout' do
    email = session[:email]
    session[:email] = nil
    flash[:notice] = "#{email} logged out successfully."
    redirect to('/')
  end
end

namespace '/api' do
  get '/status' do
    {"status": "running", "timestamp": Time.now}.to_json
  end

  post '/enroll' do
    # This next line is necessary because osqueryd does not send the
    # enroll_secret as a POST param.
    begin
      json_data = JSON.parse(request.body.read)
      params.merge!(json_data)
    rescue
    end

    @endpoint = Enroller.enroll params['enroll_secret'],
      last_version: request.user_agent,
      last_ip: request.ip
    @endpoint.node_secret
  end

  post '/config' do
    # This next line is necessary because osqueryd does not send the
    # enroll_secret as a POST param.
    begin
      params.merge!(JSON.parse(request.body.read))
    rescue
    end
    logdebug "value in node_key is #{params['node_key']}"
    client = GuaranteedEndpoint.find_by node_key: params['node_key']
    logdebug "Received endpoint: #{client.inspect}"
    client.get_config
  end

end

namespace '/configuration-groups' do
  get  do
    @groups = ConfigurationGroup.all
    erb :"configuration_groups/index"
  end

  post do
    @cg = ConfigurationGroup.create(name: params[:name])
    redirect '/configuration-groups'
  end

  namespace '/:cg_id' do
    get do
      @cg = GuaranteedConfigurationGroup.find(params[:cg_id])
      @default_config = @cg.default_config
      if @cg.canary_in_progress?
        flash[:notice] = "Canary deployment in progress."
      end
      erb :"configuration_groups/show"
    end

    post do
      @cg = GuaranteedConfigurationGroup.find(params[:cg_id])
      @cg.default_config = GuaranteedConfiguration.find(params[:default_config])
      @cg.save
      redirect "/configuration-groups/#{params[:cg_id]}"
    end

    namespace '/canary' do
      get '/cancel' do
        @cg = GuaranteedConfigurationGroup.find(params[:cg_id])
        @cg.cancel_canary
        flash[:success] = "Cancelled the canary configuration and reassigned endpoints to default"
        redirect "/configuration-groups/#{params[:cg_id]}"
      end

      get '/promote' do
        @cg = GuaranteedConfigurationGroup.find(params[:cg_id])
        @cg.promote_canary
        flash[:success] = "Promoted the canary configuration to default and reassigned remaining endpoints"
        redirect "/configuration-groups/#{params[:cg_id]}"
      end

      get '/:config_id' do
        @cg = GuaranteedConfigurationGroup.find(params[:cg_id])

        # Not using GuaranteedConfiguration here because if you try to assign
        # a missing config as the canary we need to throw an error
        @newconfig = Configuration.find(params[:config_id])
        erb :"configuration_groups/canary"
      end

      post '/:config_id' do
        @cg = GuaranteedConfigurationGroup.find(params[:cg_id])

        # Not using GuaranteedConfiguration here because if you try to assign
        # a missing config as the canary we need to throw an error
        @newconfig = Configuration.find(params[:config_id])
        if params['method'] == 'count'
          @cg.assign_config_count(@newconfig, params['count'].to_i)
          @cg.canary_config = @newconfig
          flash[:success] = "Assigned #{@newconfig.name} version #{@newconfig.version} to #{params['count']} endpoints."
        elsif params['method'] == 'percent'
          @cg.assign_config_percent(@newconfig, params['percent'].to_i)
          @cg.canary_config = @newconfig
          flash[:success] = "Assigned #{@newconfig.name} version #{@newconfig.version} to #{params['percent']}% of endpoints."
        else
          flash[:warning] = "No valid method provided"
        end
          redirect "/configuration-groups/#{params[:cg_id]}"
      end
    end


    post '/assign' do
      @cg = GuaranteedConfigurationGroup.find(params[:cg_id])
      params["assign_pct"].each do |key, value|
        if value != ""
          puts "Looks like you want to assign #{value} percent to #{key}"
          @config = GuaranteedConfiguration.find(key)
          @cg.assign_config_percent(@config, value.to_i)
          break
        end
      end
      {status:"ok"}.to_json
    end

    namespace '/configurations' do
      get '/new' do
        @cg = GuaranteedConfigurationGroup.find(params[:cg_id])
        @config = @cg.configurations.build
        erb :"configurations/new"
      end

      post do
        @cg = GuaranteedConfigurationGroup.find(params[:cg_id])
        puts "we're good"
        @config = @cg.configurations.build(params[:config])
        puts @config.inspect
        if @config.save
          redirect "/configuration-groups/#{@cg.id}"
        else
          @config.errors.messages.to_s
        end
      end
    end
  end
end
