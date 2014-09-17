require 'net/http'

module AS2
  class Client
    def initialize(partner_name)
      @partner = Config.partners[partner_name]
      unless @partner
        raise "Partner #{partner_name} is not registered"
      end
      @info = Config.server_info
    end

    Result = Struct.new :success, :response, :mic_matched, :mid_matched, :body, :disp_code

    def send_file(file_name)
      http = Net::HTTP.new(@partner.url.host, @partner.url.port)
      http.use_ssl = @partner.url.scheme == 'https'
      # http.set_debug_output $stderr
      http.start do
        req = Net::HTTP::Post.new @partner.url.path
        req['AS2-Version'] = '1.2'
        req['AS2-From'] = @info.name
        req['AS2-To'] = @partner.name
        req['Subject'] = 'AS2 EDI Transaction'
        req['Content-Type'] = 'application/pkcs7-mime; smime-type=enveloped-data; name=smime.p7m'
        req['Disposition-Notification-To'] = @info.url.to_s
        req['Disposition-Notification-Options'] = 'signed-receipt-protocol=optional, pkcs7-signature; signed-receipt-micalg=optional, sha1'
        req['Content-Disposition'] = 'attachment; filename="smime.p7m"'
        req['Recipient-Address'] = @info.url.to_s
        req['Content-Transfer-Encoding'] = 'base64'
        req['Message-ID'] = "<#{@info.name}-#{Time.now.strftime('%Y%m%d%H%M%S')}@#{@info.url.host}>"

        body = StringIO.new
        body.puts "Content-Type: application/EDI-Consent"
        body.puts "Content-Transfer-Encoding: base64"
        body.puts "Content-Disposition: attachment; filename=#{file_name}"
        body.puts
        body.puts [File.read(file_name)].pack("m*")

        mic = OpenSSL::Digest::SHA1.base64digest(body.string.gsub(/\n/, "\r\n"))

        pkcs7 = OpenSSL::PKCS7.sign @info.certificate, @info.pkey, body.string
        pkcs7.detached = true
        smime_signed = OpenSSL::PKCS7.write_smime pkcs7, body.string
        pkcs7 = OpenSSL::PKCS7.encrypt [@partner.certificate], smime_signed
        smime_encrypted = OpenSSL::PKCS7.write_smime pkcs7

        req.body = smime_encrypted.sub(/^.+?\n\n/m, '')

        resp = http.request(req)

        success = resp.code == '200'
        mic_matched = false
        mid_matched = false
        disp_code = nil
        body = nil
        if success
          body = resp.body

          smime = OpenSSL::PKCS7.read_smime "Content-Type: #{resp['Content-Type']}\r\n#{body}"
          smime.verify [@partner.certificate], Config.store

          mail = Mail.new smime.data
          mail.parts.each do |part|
            case part.content_type
            when 'text/plain'
              body = part.body
            when 'message/disposition-notification'
              options = {}
              part.body.to_s.lines.each do |line|
                if line =~ /^([^:]+): (.+)$/
                  options[$1] = $2
                end
              end

              if req['Message-ID'] == options['Original-Message-ID']
                mid_matched = true
              else
                success = false
              end

              if options['Received-Content-MIC'].start_with?(mic)
                mic_matched = true
              else
                success = false
              end

              disp_code = options['Disposition']
              success = disp_code.end_with?('processed')
            end
          end
        end
        Result.new success, resp, mic_matched, mid_matched, body, disp_code
      end
    end
  end
end
