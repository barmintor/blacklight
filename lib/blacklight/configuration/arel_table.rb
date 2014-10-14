require 'ansr'
module Blacklight
  class Configuration::BigTable < Ansr::Arel::BigTable
    attr_accessor :configuration, :name
    def initialize(configuration)
      super(configuration.model)
      @configuration = configuration
      @name = @configuration.solr_path
      configure_fields do |configs|
      end
      fields do |list|
      end
      sorts do |list|
      end
      facets do |list|
      end
    end
    def at(name)
      t = self.class.new(configuration.dup)
      t.fields do |list|
        list += fields
      end
      t.sorts do |list|
        list += sorts
      end
      t.facets do |list|
        list += facets
      end
      t.configure_fields do |configs|
        configs.merge(configure_fields)
      end
      t.name= name
      t
    end
  end
end