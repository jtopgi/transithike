source 'https://rubygems.org'
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby file: '.ruby-version'

# Bundle edge Rails instead: gem 'rails', github: 'rails/rails'
gem 'rails', '~> 8.1.3', '>= 8.1.3.1'
# Use postgresql as the database for Active Record
gem 'pg', '~> 1.6'
# Use Puma as the app server
gem 'puma', '~> 8.0'
gem 'propshaft', '~> 1.3'
gem 'jsbundling-rails', '~> 1.3'
# Build JSON APIs with ease. Read more: https://github.com/rails/jbuilder
gem 'jbuilder', '~> 2.15'
# Use Redis adapter to run Action Cable in production
# gem 'redis', '~> 4.0'
# Use Active Model has_secure_password
# gem 'bcrypt', '~> 3.1.7'

# Use Active Storage variant
# gem 'image_processing', '~> 1.2'

# Reduces boot times through caching; required in config/boot.rb
gem 'bootsnap', '~> 1.26', require: false

# HTTP/REST API client library.
gem 'faraday', '~> 2.14'

group :development, :test do
  gem 'brakeman', '~> 8.0', require: false
  gem 'bundler-audit', '~> 0.9', require: false
end

group :development do
  # Access an interactive console on exception pages or by calling 'console' anywhere in the code.
  gem 'web-console', '~> 4.3'
  gem 'listen', '~> 3.10'
end

group :test do
  # Adds support for Capybara system testing and selenium driver
  gem 'capybara', '~> 3.40'
  gem 'selenium-webdriver', '~> 4.49'
end
