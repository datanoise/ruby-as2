require 'as2'
require 'rack'

AS2.configure do |conf|
  conf.name = 'WebTM'
  conf.url = 'http://localhost:3000/as2'
  conf.certificate = 'server.crt'
  conf.pkey = 'server.key'
  conf.add_partner do |partner|
    partner.name = 'mycompanyAS2'
    partner.url = 'http://localhost:8080/as2/HttpReceiver'
    partner.certificate = 'partner.crt'
  end
end

handler = AS2::Server.new do |filename, body|
  puts "SUCCESSFUL DOWNLOAD"
  puts "FILENAME: #{filename}"
  puts
  puts body
  raise "Test error message" if filename.end_with?('edi')
end

builder = Rack::Builder.new do
  use Rack::CommonLogger
  map '/as2' do
    run handler
  end
end

Rack::Handler::Thin.run builder, Port: 3000
