# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'bankscrap/ing/version'

Gem::Specification.new do |spec|
  spec.name     = 'bankscrap-ing'
  spec.version  = Bankscrap::ING::VERSION
  spec.authors  = ['Raúl']
  spec.email    = ['raulmarcosl@gmail.coms']
  spec.summary  = 'ING adapter for Bankscrap'
  spec.homepage = ''
  spec.license  = 'MIT'

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_runtime_dependency 'bankscrap',   '~> 2.0.0'
  spec.add_runtime_dependency 'rmagick',     '~> 2.2', '>= 2.2.2'

  spec.add_development_dependency 'bundler', '~> 1.7'
  spec.add_development_dependency 'rake',    '~> 10.0'
  spec.add_development_dependency 'byebug',  '~> 8.2', '>= 8.2.5'
  spec.add_development_dependency 'rubocop', '~> 0.39.0'
end
