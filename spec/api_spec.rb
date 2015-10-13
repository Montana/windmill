require 'spec_helper'


describe 'The osquery TLS api' do
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  before do
    @cg = ConfigurationGroup.create(name: "default")
    @empty = ConfigurationGroup.create(name: "empty")
    @config = @cg.configurations.create(name:"test", version:1, notes:"test", config_json: {test:"test"}.to_json)
    @endpoint = @cg.endpoints.create(node_key:SecureRandom.uuid)
  end

  valid_node_key = ""

  it "sets a new client's config_count to zero" do
    post '/api/enroll', {enroll_secret: "valid_test"}
    expect(last_response).to be_ok
    json = JSON.parse(last_response.body)
    client = Endpoint.find_by node_key: json['node_key']
    expect(client.config_count).to eq(0)
  end

  it "sets a new clients last_config_time to nil" do
    post '/api/enroll', {enroll_secret: "valid_test"}
    expect(last_response).to be_ok
    json = JSON.parse(last_response.body)
    client = Endpoint.find_by node_key: json['node_key']
    expect(client.last_config_time).to eq(nil)
  end

  it "counts how many times a client has pulled its config" do
    client = Endpoint.last
    config_count = client.config_count
    post '/api/config', node_key: client.node_key
    client.reload
    expect(client.config_count).to eq(config_count + 1)
  end

  it "updates the timestamp in last_config_time when a client pulls its config" do
    @client = Endpoint.last
    config_time = @client.last_config_time || Time.now
    post '/api/config', node_key: @client.node_key
    @client.reload
    expect(@client.last_config_time).to be > config_time
  end

  it "returns a status" do
    get '/api/status'
    expect(last_response).to be_ok
    json = JSON.parse(last_response.body)
    expect(json["status"]).to eq("running")
    expect(json).to have_key("timestamp")
  end

  it "enrolls a node with a valid enroll secret" do
    pre_enroll_endpoint_count = Endpoint.count
    post '/api/enroll', {enroll_secret: "valid_test"}
    expect(last_response).to be_ok
    json = JSON.parse(last_response.body)
    expect(json).to have_key("node_key")
    valid_node_key = json["node_key"]
    expect(Endpoint.count).to eq(pre_enroll_endpoint_count + 1)
  end

  it "rejects a node with an invalid enroll secret" do
    post '/api/enroll', enroll_secret: "invalid_test"
    expect(last_response).to be_ok
    json = JSON.parse(last_response.body)
    expect(json).to have_key("node_invalid")
    expect(json["node_invalid"]).to eq(true)
  end

  it "records ConfigurationGroup and identifier when a node enrolls with a valid enroll secret" do
    post '/api/enroll', {enroll_secret: "hostname:default:valid_test"}
    expect(last_response).to be_ok
    json = JSON.parse(last_response.body)
    expect(json).to have_key("node_key")
    valid_node_key = json["node_key"]
    @endpoint = GuaranteedEndpoint.find_by node_key: valid_node_key
    expect(@endpoint.identifier).to eq("hostname")
    expect(@endpoint.configuration_group_id).to eq(ConfigurationGroup.find_by(name:"default").id)
  end

  it "records just the ConfigurationGroup when a node enrolls with a valid enroll secret" do
    post '/api/enroll', {enroll_secret: "default:valid_test"}
    expect(last_response).to be_ok
    json = JSON.parse(last_response.body)
    expect(json).to have_key("node_key")
    valid_node_key = json["node_key"]
    @endpoint = GuaranteedEndpoint.find_by node_key: valid_node_key
    expect(@endpoint.identifier).to eq(nil)
    expect(@endpoint.configuration_group_id).to eq(ConfigurationGroup.find_by(name:"default").id)
  end

  it "enrolls an endpoint into the default ConfigurationGroup when an invalid group name is supplied" do
    post '/api/enroll', {enroll_secret: "hostname:invalid:valid_test"}
    expect(last_response).to be_ok
    json = JSON.parse(last_response.body)
    expect(json).to have_key("node_key")
    valid_node_key = json["node_key"]
    @endpoint = GuaranteedEndpoint.find_by node_key: valid_node_key
    expect(@endpoint.identifier).to eq("hostname")
    expect(@endpoint.configuration_group_id).to eq(GuaranteedConfigurationGroup.find_by(name: "default").id)
  end

  it "enrolls an endpoint into the default ConfigurationGroup when a valid group name is supplied but the group has no configurations" do
    post '/api/enroll', {enroll_secret: "empty-test:empty:valid_test"}
    expect(last_response).to be_ok
    json = JSON.parse(last_response.body)
    expect(json).to have_key("node_key")
    valid_node_key = json["node_key"]
    @endpoint = GuaranteedEndpoint.find_by node_key: valid_node_key
    expect(@endpoint.identifier).to eq("empty-test")
    expect(@endpoint.configuration_group_id).to eq(GuaranteedConfigurationGroup.find_by(name: "default").id)
  end

  it "returns a configuration with a valid node secret" do
    @endpoint = Endpoint.last
    post '/api/config', node_key: @endpoint.node_key
    expect(last_response).to be_ok
    expect(last_response.body).to match(@endpoint.get_config)
  end


  it "rejects a request for configuration from a node with an invalid node secret" do
    post '/api/config', node_key: "invalid_test"
    expect(last_response).to be_ok
    json = JSON.parse(last_response.body)
    expect(json).to have_key("node_invalid")
    expect(json["node_invalid"]).to eq(true)
  end
end
