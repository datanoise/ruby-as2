require 'rack'
require 'pry'
require 'stringio'
require 'openssl'
require 'mail'

$pkey = OpenSSL::PKey.read File.read('server.key')
$cert = OpenSSL::X509::Certificate.new File.read('server.crt')
$pcert = OpenSSL::X509::Certificate.new File.read('partner.crt')

$store = OpenSSL::X509::Store.new
$store.add_cert $cert
$store.add_cert $pcert

class MimeGenerator
  class Part
    def initialize
      @parts = []
      @body = ""
      @headers = {}
    end

    def [](name)
      @headers[name]
    end

    def []=(name, value)
      @headers[name] = value
    end

    def body
      @body
    end

    def body=(body)
      unless @parts.empty?
        raise "Cannot add plain budy to multipart"
      end
      @body = body
    end

    def add_part(part)
      gen_id unless @id
      @parts << part
      @body = nil
    end

    def multipart?
      ! @parts.empty?
    end

    def write(io)
      @headers.each do |name, value|
        if multipart? && name =~ /content-type/i
          io.print "#{name}: #{value}; \r\n"
          io.print "\tboundary=\"---=_Part_#{@id}\"\r\n"
        else
          io.print "#{name}: #{value}\r\n"
        end
      end
      io.print "\r\n"
      if @parts.empty?
        io.print @body, "\r\n"
      else
        @parts.each do|p|
          io.print "------=_Part_#{@id}\r\n"
          p.write(io)
        end
        io.print "------=_Part_#{@id}--\r\n"
      end
      io.print "\r\n"
    end

    private

    @@counter = 0
    def gen_id
      @@counter += 1 
      @id = "#{@@counter}_#{Time.now.strftime('%Y%m%d%H%M%S%L')}"
    end
  end
end

class Handler
  def call(env)
    smime_data = StringIO.new
    smime_data.puts "To: #{env['HTTP_AS2_TO']}"
    smime_data.puts "From: #{env['HTTP_AS2_FROM']}"
    smime_data.puts "Subject: #{env['HTTP_SUBJECT']}"
    smime_data.puts 'MIME-Version: 1.0'
    smime_data.puts 'Content-Disposition: attachment; filename="smime_data.p7m"'
    smime_data.puts 'Content-Type: application/pkcs7-mime; smime_data-type=enveloped-data; name="smime_data.p7m"'
    smime_data.puts 'Content-Transfer-Encoding: base64'
    smime_data.puts
    smime_data.puts [env['rack.input'].read].pack('m*')

    open('message.data', 'w'){|f| f << smime_data.string}
    smime = OpenSSL::PKCS7.read_smime(smime_data.string)
    smime_decrypted = smime.decrypt $pkey, $cert
    smime = OpenSSL::PKCS7.read_smime smime_decrypted
    smime.verify [$pcert], $store

    mic = OpenSSL::Digest::SHA1.base64digest(smime.data)

    mail = Mail.new smime.data

    part = if mail.has_attachments?
             mail.attachments.find{|a| a.content_type == "application/edi-consent"}
           else
             mail
           end
    open(part.filename, 'w'){|f| f << part.body}

    report = MimeGenerator::Part.new
    report['Content-Type'] = 'multipart/report; report-type=disposition-notification'

    text = MimeGenerator::Part.new
    text['Content-Type'] = 'text/plain'
    text['Content-Transfer-Encoding'] = '7bit'
    text.body = "The AS2 message has been received successfully"

    report.add_part text

    notification = MimeGenerator::Part.new
    notification['Content-Type'] = 'message/disposition-notification'
    notification['Content-Transfer-Encoding'] = '7bit'

    options = {
      'Reporting-UA' => 'WebTM',
      'Original-Recipient' => 'rfc822; WebTM',
      'Final-Recipient' => 'rfc822; WebTM',
      'Original-Message-ID' => env['HTTP_MESSAGE_ID'],
      'Disposition' => 'automatic-action/MDN-sent-automatically; processed',
      'Received-Content-MIC' => "#{mic}, sha1"
    }
    notification.body = options.map{|n, v| "#{n}: #{v}"}.join("\r\n")
    report.add_part notification

    msg_out = StringIO.new

    report.write msg_out

    pkcs7 = OpenSSL::PKCS7.sign $cert, $pkey, msg_out.string
    pkcs7.detached = true
    smime_signed = OpenSSL::PKCS7.write_smime pkcs7, msg_out.string

    content_type = smime_signed[/^Content-Type: (.+?)$/m, 1]
    smime_signed.sub!(/\A.+?^(?=---)/m, '')

    headers = {}
    headers['Content-Type'] = content_type
    headers['MIME-Version'] = '1.0'
    headers['Message-ID'] = "<webtm-#{Time.now.strftime('%Y%m%d%H%M%S')}@ryderwebtm.com>"
    headers['AS2-From'] = 'WebTM'
    headers['AS2-To'] = env['HTTP_AS2_FROM']
    headers['AS2-Version'] = '1.2'
    headers['Connection'] = 'close'
    # binding.pry

    [200, headers, ["\r\n" + smime_signed]]
  end
end

builder = Rack::Builder.new do
  use Rack::CommonLogger
  map '/as2' do
    run Handler.new
  end
end

Rack::Handler::Thin.run builder, Port: 3000
