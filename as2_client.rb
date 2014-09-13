require 'net/http'
require 'openssl'
require 'mail'
require 'pry'

$pkey = OpenSSL::PKey.read File.read('server.key')
$cert = OpenSSL::X509::Certificate.new File.read('server.crt')
$pcert = OpenSSL::X509::Certificate.new File.read('partner.crt')

$store = OpenSSL::X509::Store.new
$store.add_cert $cert
$store.add_cert $pcert

http = Net::HTTP.new('localhost', 8080)
http.set_debug_output $stderr
http.start do
  req = Net::HTTP::Post.new '/as2/HttpReceiver'
  req['AS2-Version'] = '1.2'
  req['AS2-From'] = 'WebTM'
  req['AS2-To'] = 'mycompanyAS2'
  req['Subject'] = 'EDI Transaction'
  req['Content-Type'] = 'application/pkcs7-mime; smime-type=enveloped-data; name=smime.p7m'
  req['Disposition-Notification-To'] = 'http://localhost:3000/as2'
  req['Disposition-Notification-Options'] = 'signed-receipt-protocol=optional, pkcs7-signature; signed-receipt-micalg=optional, sha1'
  req['Content-Disposition'] = 'attachment; filename="smime.p7m"'
  req['Recipient-Address'] = 'http://localhost:8080/as2'
  req['Content-Transfer-Encoding'] = 'base64'
  req['Message-ID'] = "<webtm-#{Time.now.strftime('%Y%m%d%H%M%S')}@ryderwebtm.com>"

  file_name = ARGV.first

  body = StringIO.new
  body.puts "Content-Type: application/EDI-Consent"
  body.puts "Content-Transfer-Encoding: base64"
  body.puts "Content-Disposition: attachment; filename=#{file_name}"
  body.puts
  body.puts [File.read(file_name)].pack("m*")

  mic = OpenSSL::Digest::SHA1.base64digest(body.string.gsub(/\n/, "\r\n"))

  pkcs7 = OpenSSL::PKCS7.sign $cert, $pkey, body.string
  pkcs7.detached = true
  smime_signed = OpenSSL::PKCS7.write_smime pkcs7, body.string
  pkcs7 = OpenSSL::PKCS7.encrypt [$pcert], smime_signed
  smime_encrypted = OpenSSL::PKCS7.write_smime pkcs7

  req.body = smime_encrypted.sub(/^.+?\n\n/m, '')

  resp = http.request(req)
  body = resp.body

  open('resp.data', 'w'){|f| f << body }

  smime = OpenSSL::PKCS7.read_smime "Content-Type: #{resp['Content-Type']}\r\n#{body}"
  smime.verify [$pcert], $store

  mail = Mail.new smime.data
  mail.parts.each do |part|
    case part.content_type
    when 'text/plain'
      puts "Msg: #{part.body}"
    when 'message/disposition-notification'
      options = {}
      part.body.to_s.lines.each do |line|
        if line =~ /^([^:]+): (.+)$/
          options[$1] = $2
        end
      end

      if req['Message-ID'] == options['Original-Message-ID']
        puts "Message ID matches"
      else
        puts "ERR: Message ID doesn't match"
      end

      if options['Received-Content-MIC'].start_with?(mic)
        puts "MIC matches"
      else
        puts "ERR: MIC doesn't match"
      end

      if options['Disposition'].end_with?('processed')
        puts "Successful response"
      else
        puts "ERR: Response #{options['Disposition']}"
      end
    end
  end

end
