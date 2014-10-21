require 'as2'
require 'pry'

AS2.configure do |conf|
  conf.name = 'MyName'
  conf.url = 'http://localhost:3000/as2'
  conf.certificate = 'server.crt'
  conf.pkey = 'server.key'
  conf.domain = 'mydomain.com'
  conf.add_partner do |partner|
    partner.name = 'mycompanyAS2'
    partner.url = 'http://localhost:8080/as2/HttpReceiver'
    partner.certificate = 'partner.crt'
  end
end

client = AS2::Client.new 'mycompanyAS2'
result = client.send_file(ARGV.first)
p result
