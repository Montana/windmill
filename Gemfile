source "https://rubygems.org"
ruby "2.2.2"

gem 'sinatra'
gem 'sinatra-contrib'
gem 'puma'
gem 'json'
gem 'activerecord'
gem 'sinatra-activerecord'
gem 'sinatra-flash'
gem 'omniauth'
gem 'omniauth-github'
gem 'omniauth-heroku'
gem 'omniauth-google-oauth2'
gem 'encrypted_cookie'

group :test, :development do
  gem 'sqlite3'
  gem 'database_cleaner'
  gem 'rspec'
  gem 'rack-test'
  gem 'capybara'
end

group :production do
  gem 'pg'
end
