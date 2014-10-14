module Blacklight
  ##
  # This module contains methods that are specified by SolrHelper.solr_search_params_logic
  # They transform user parameters into parameters that are sent as a request to Solr when
  # RequestBuilders#solr_search_params is called.
  #
  module RequestBuilders
    extend ActiveSupport::Concern

    included do
      # We want to install a class-level place to keep 
      # solr_search_params_logic method names. Compare to before_filter,
      # similar design. Since we're a module, we have to add it in here.
      # There are too many different semantic choices in ruby 'class variables',
      # we choose this one for now, supplied by Rails. 
      class_attribute :relation_decorators

      # Set defaults. Each symbol identifies a _method_ that must be in
      # this class, taking two parameters (relation, user_parameters)
      # Can be changed in local apps or by plugins, eg:
      # CatalogController.include ModuleDefiningNewMethod
      # CatalogController.solr_search_params_logic += [:new_method]
      # CatalogController.solr_search_params_logic.delete(:we_dont_want)
      self.relation_decorators = [:add_query, :add_filters, :add_facetting, :add_field_projections, :add_paging, :add_sorting, :dedupe_group_and_facet ]
    end

    # @returns a relation for searching the configured model's datastore.
    # The CatalogController #index action uses this.
    # Solr parameters can come from a number of places. From lowest
    # precedence to highest:
    #  1. General defaults in blacklight config (are trumped by)
    #  2. defaults for the particular search field identified by  params[:search_field] (are trumped by) 
    #  3. certain parameters directly on input HTTP query params 
    #     * not just any parameter is grabbed willy nilly, only certain ones are allowed by HTTP input)
    #     * for legacy reasons, qt in http query does not over-ride qt in search field definition default. 
    #  4.  extra parameters passed in as argument.
    #
    # spellcheck.q will be supplied with the [:q] value unless specifically
    # specified otherwise. 
    #
    # Incoming parameter :f is mapped to :fq solr parameter.
    def relation_for_params(user_params = params || {})

      blacklight_config.default_relation(user_params).tap do |relation|
        relation_decorators.each do |method_name|
          send(method_name, relation, user_params)
        end
      end
    end

    def add_solr_params(relation, user_params={})
      # legacy behavior of user param :qt is passed through, but over-ridden
      # by actual search field config if present. We might want to remove
      # this legacy behavior at some point. It does not seem to be currently
      # rspec'd.
      relation.qt!(user_params[:qt]) if user_params[:qt]
      
      search_field_def = search_field_def_for_key(user_params[:search_field])
      if (search_field_def)     
        relation.qt!(search_field_def.qt) if search_field_def.qt
        relation = search_field_def.add_params(relation) if search_field_def.respond_to? :add_params
      end
    end
    
    ##
    # Take the user-entered query, and put it in the solr params, 
    # including config's "search field" params for current search field. 
    # also include setting spellcheck.q. 
    def add_query(relation, user_params={})
      ###
      # Merge in search field configured values, if present, over-writing general
      # defaults
      ###
      
      ##
      # Create Solr 'q' including the user-entered q, prefixed by any
      # solr LocalParams in config, using solr LocalParams syntax. 
      # http://wiki.apache.org/solr/LocalParams
      ##
      user_params = user_params.dup         
      search_field_def = search_field_def_for_key(user_params.delete(:search_field))
      if (search_field_def && hash = search_field_def.local_parameters)
        model.table.configure_fields do |config|
          unless config[search_field_def.field]
            config[search_field_def.field] =  search_field_def.local_parameters
          end
        end
        relation.where!(search_field_def.key => user_params.delete(:q))
      else
        user_params.delete(:f)
        user_params.each {|k,v| relation.where!(k.to_sym => v)}
      end            
    end

    ##
    # Add any existing facet limits, stored in app-level HTTP query
    # as :f, to solr as appropriate :fq query. 
    def add_filters(relation, user_params)   

      # :fq, map from :f. 
      if ( user_params[:f])
        f_request_params = user_params[:f] 
        
        f_request_params.each_pair do |facet_field, value_list|
          Array(value_list).each do |value|
            next if value.blank? # skip empty strings
            relation.filter!(facet_field => value)
          end              
        end      
      end
    end
    
    ##
    # Add appropriate Solr facetting directives in, including
    # taking account of our facet paging/'more'.  This is not
    # about solr 'fq', this is about solr facet.* params. 
    def add_facetting(relation, user_params)
      # While not used by BL core behavior, legacy behavior seemed to be
      # to accept incoming params as "facet.field" or "facets", and add them
      # on to any existing facet.field sent to Solr. Legacy behavior seemed
      # to be accepting these incoming params as arrays (in Rails URL with []
      # on end), or single values. At least one of these is used by
      # Stanford for "faux hieararchial facets". 
      if user_params.has_key?("facet.field") || user_params.has_key?("facets")
        facets = ( [user_params["facet.field"], user_params["facets"]].flatten.compact ).uniq!
        facets.each {|facet| relation.facet!(facet.to_sym)}
      end

      blacklight_config.facet_fields.select { |field_name,facet|
        facet.include_in_request || (facet.include_in_request.nil? && blacklight_config.add_facet_fields_to_solr_request)
      }.each do |field_name, facet|
        facet_opts = {}
        facet_opts[:ex] = facet.ex if facet.ex
        case 
          when facet.pivot
            facet_opts[:pivot] = facet.pivot.join(",")
          when facet.query
            facet_opts[:query] = facet.query
        end

        facet_opts[:sort] = facet.sort if facet.sort

        facet_opts.merge!(facet.params) if facet.params

        # Support facet paging and 'more'
        # links, by sending a facet.limit one more than what we
        # want to page at, according to configured facet limits.
        facet_opts[:limit] = (facet_limit_for(field_name) + 1) if facet_limit_for(field_name)
        relation.facet!(facet.field, facet_opts)
      end
    end

    def add_field_projections(relation, user_parameters)
      blacklight_config.show_fields.select(&method(:should_add_to_solr)).each do |field_name, field|
        if field.solr_params
          relation.select!(field.field, field.params)
        else
          relation.select!(field.field)
        end
      end

      blacklight_config.index_fields.select(&method(:should_add_to_solr)).each do |field_name, field|
        if field.highlight
          relation.highlight!(field.field)
        end

        if field.solr_params
          relation.select!(field.field, field.params)
        else
          relation.select!(field.field)
        end
      end
    end

    ###
    # copy paging params from BL app over to solr, changing
    # app level per_page and page to Solr rows and start. 
    def add_paging(relation, user_params)
      
      # user-provided parameters should override any default row
      limit = (user_params[:rows].blank?) ? nil : (user_params[:rows].to_i) 
      limit = (user_params[:per_page].to_i)  unless user_params[:per_page].blank?

      # ensure we don't excede the max page size
      limit = blacklight_config.max_per_page if limit and limit.to_i > blacklight_config.max_per_page
      unless user_params[:page].blank?
        if limit.blank?
          # set a reasonable default
          Rails.logger.info "Solr :rows parameter not set (by the user, configuration, or default solr parameters); using 10 rows by default"
          limit = 10
        end
        offset = (user_params[:page].to_i > 0) ? (limit * (user_params[:page].to_i - 1)) : 0
        relation.offset!(offset)
      end

      limit ||= blacklight_config.per_page.first unless blacklight_config.per_page.blank?

      limit = blacklight_config.max_per_page if limit > blacklight_config.max_per_page
      relation.limit!(limit)
    end

    ###
    # copy sorting params from BL app over to solr
    def add_sorting(relation, user_params)
      if user_params[:sort].blank? and sort_field = blacklight_config.default_sort_field
        # no sort param provided, use default
        relation.order!(sort_field.sort) unless sort_field.sort.blank?
      elsif sort_field = blacklight_config.sort_fields[user_params[:sort]]
        # check for sort field key  
        relation.order!(sort_field.sort) unless sort_field.sort.blank?
      else 
        # just pass the key through
        relation.order!(user_params[:sort])
      end
    end

    # Remove the group parameter if we've faceted on the group field (e.g. for the full results for a group)
    def add_group_config_to_solr solr_parameters, user_parameters
      dedupe_group_and_facet(solr_parameters, user_parameters)
    end

    def dedupe_group_and_facet relation, user_parameters
      if user_parameters[:f] and user_parameters[:f][grouped_key_for_results]
        relation.unscope(:group)
      end
    end

  end
end
