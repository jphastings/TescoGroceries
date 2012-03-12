require 'rubygems'
require 'rake'

begin
  require 'jeweler'
  Jeweler::Tasks.new do |gem|
    gem.name = "tesco"
    gem.summary = %Q{An extremely straightforward library for the Tesco Grocery API}
    gem.description = %Q{Search the Tesco Groceries API, through a very object oriented library}
    gem.email = "jphastings@gmail.com"
    gem.homepage = "http://github.com/jphastings/TescoGroceries"
    gem.authors = ["JP Hastings-Spital"]
    # gem is a Gem::Specification... see http://www.rubygems.org/read/chapter/20 for additional settings
  end
  Jeweler::GemcutterTasks.new
rescue LoadError
  puts "Jeweler (or a dependency) not available. Install it with: gem install jeweler"
end

task :default => :build