$: << "./lib"
require 'as2'

Gem::Specification.new do |s|
  s.name        = 'as2'
  s.version     = AS2::VERSION
  s.date        = '2010-09-21'
  s.summary     = "Implementation of AS2 protocol"
  s.description = "Protocol spec: http://www.ietf.org/rfc/rfc4130.txt"
  s.authors     = ["Kent Sibilev"]
  s.email       = 'ksibilev@yahoo.com'
  s.files       = %w|README LICENSE| + %x|git ls-files lib|.split
  s.homepage    = 'http://github.com/datanoise/ruby-as2'
  s.license     = 'MIT'
  s.add_dependency('mail', "~> 2.6")
end
