require 'rack'
require 'logger'
require 'stringio'

module AS2
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
            io.print "\tboundary=\"----=_Part_#{@id}\"\r\n"
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

  class Server
    HEADER_MAP = {
      'To' => 'HTTP_AS2_TO',
      'From' => 'HTTP_AS2_FROM',
      'Subject' => 'HTTP_SUBJECT',
      'MIME-Version' => 'HTTP_MIME_VERSION',
      'Content-Disposition' => 'HTTP_CONTENT_DISPOSITION',
      'Content-Type' => 'CONTENT_TYPE',
    }

    attr_accessor :logger

    def initialize(&block)
      @block = block
      @info = Config.server_info
    end

    def call(env)
      if env['HTTP_AS2_TO'] != @info.name
        return send_error(env, "Invalid destination name #{env['HTTP_AS2_TO']}")
      end

      partner = Config.partners[env['HTTP_AS2_FROM']]
      unless partner
        return send_error(env, "Invalid partner name #{env['HTTP_AS2_FROM']}")
      end

      smime_data = StringIO.new
      HEADER_MAP.each do |name, value|
        smime_data.puts "#{name}: #{env[value]}"
      end
      smime_data.puts 'Content-Transfer-Encoding: base64'
      smime_data.puts
      smime_data.puts [env['rack.input'].read].pack('m*')

      smime = OpenSSL::PKCS7.read_smime(smime_data.string)
      smime_decrypted = smime.decrypt @info.pkey, @info.certificate
      smime = OpenSSL::PKCS7.read_smime smime_decrypted
      smime.verify [partner.certificate], Config.store

      mic = OpenSSL::Digest::SHA1.base64digest(smime.data)

      mail = Mail.new smime.data

      part = if mail.has_attachments?
               mail.attachments.find{|a| a.content_type == "application/edi-consent"}
             else
               mail
             end
      if @block
        begin
          @block.call part.filename, part.body
        rescue
          return send_error(env, $!.message)
        end
      end
      send_mdn(env, mic)
    end

    private

    def logger(env)
      @logger ||= Logger.new env['rack.errors']
    end

    def send_error(env, msg)
      logger(env).error msg
      send_mdn env, nil, msg
    end

    def send_mdn(env, mic, failed = nil)
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
        'Original-Message-ID' => env['HTTP_MESSAGE_ID']
      }
      if failed
        options['Disposition'] = 'automatic-action/MDN-sent-automatically; failed'
        options['Failure'] = failed
      else
        options['Disposition'] = 'automatic-action/MDN-sent-automatically; processed'
      end
      options['Received-Content-MIC'] = "#{mic}, sha1" if mic
      notification.body = options.map{|n, v| "#{n}: #{v}"}.join("\r\n")
      report.add_part notification

      msg_out = StringIO.new

      report.write msg_out

      pkcs7 = OpenSSL::PKCS7.sign @info.certificate, @info.pkey, msg_out.string
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

      [200, headers, ["\r\n" + smime_signed]]
    end
  end
end
