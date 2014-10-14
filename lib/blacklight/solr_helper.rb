# -*- encoding : utf-8 -*-
# SolrHelper is a controller layer mixin. It is in the controller scope: request params, session etc.
# 
# NOTE: Be careful when creating variables here as they may be overriding something that already exists.
# The ActionController docs: http://api.rubyonrails.org/classes/ActionController/Base.html
#
# Override these methods in your own controller for customizations:
# 
#   class CatalogController < ActionController::Base
#   
#     include Blacklight::Catalog
#   
#     def solr_search_params
#       super.merge :per_page=>10
#     end
#   end
#
# Or by including in local extensions:
#   module LocalSolrHelperExtension
#     [ local overrides ]
#   end
#
#   class CatalogController < ActionController::Base
#   
#     include Blacklight::Catalog
#     include LocalSolrHelperExtension
#   
#     def solr_search_params
#       super.merge :per_page=>10
#     end
#   end
#
# Or by using ActiveSupport::Concern:
#
#   module LocalSolrHelperExtension
#     extend ActiveSupport::Concern
#     include Blacklight::SolrHelper
#
#     [ local overrides ]
#   end
#
#   class CatalogController < ApplicationController
#     include LocalSolrHelperExtension
#     include Blacklight::Catalog
#   end  

module Blacklight::SolrHelper
  extend ActiveSupport::Concern
  extend Deprecation
  include Blacklight::SearchFields
  include Blacklight::Facet
  include ActiveSupport::Benchmarkable

  included do
    if self.respond_to?(:helper_method)
      helper_method(:facet_limit_for)
    end

    include Blacklight::RequestBuilders

    # ActiveSupport::Benchmarkable requires a logger method
    unless instance_methods.include? :logger
      def logger
        nil
      end
    end
  end

  DEFAULT_FACET_LIMIT = 10

  ##
  # Execute a solr query
  # @see [RSolr::Client#send_and_receive]
  # @overload find(solr_path, params)
  #   Execute a solr query at the given path with the parameters
  #   @param [String] solr path (defaults to blacklight_config.solr_path)
  #   @param [Hash] parameters for RSolr::Client#send_and_receive
  # @overload find(params)
  #   @param [Hash] parameters for RSolr::Client#send_and_receive
  # @return [Blacklight::SolrResponse] the solr response object
  private
  def find(*args)
    # In later versions of Rails, the #benchmark method can do timing
    # better for us. 
    benchmark("Solr fetch", level: :debug) do
      solr_params = args.extract_options!
      rel = blacklight_config.model.spawn
      rel.as!(solr_params[:qt] ||= blacklight_config.qt)
      unless args.first.nil? or args.first.eql? blacklight_config.solr_path
        rel.from!(blacklight_config.table.at(args.first))
      else
        rel.from!(blacklight_config.table.at(blacklight_config.solr_path))
      end
      
      rel.load

      Rails.logger.debug("Solr query: #{solr_params.inspect}")
      Rails.logger.debug("Solr response: #{rel.inspect}") if defined?(::BLACKLIGHT_VERBOSE_LOGGING) and ::BLACKLIGHT_VERBOSE_LOGGING
      rel
    end
  rescue Errno::ECONNREFUSED => e
    raise Blacklight::Exceptions::ECONNREFUSED.new("Unable to connect to Solr instance using #{blacklight_solr.inspect}")
  end
    
  public 
  # A helper method used for generating solr LocalParams, put quotes
  # around the term unless it's a bare-word. Escape internal quotes
  # if needed. 
  def solr_param_quote(val, options = {})
    options[:quote] ||= '"'
    unless val =~ /^[a-zA-Z0-9$_\-\^]+$/
      val = options[:quote] +
        # Yes, we need crazy escaping here, to deal with regexp esc too!
        val.gsub("'", "\\\\\'").gsub('"', "\\\\\"") + 
        options[:quote]
    end
    return val
  end
    
  # a solr query method
  # given a user query, return a solr response containing both result docs and facets
  # - mixes in the Blacklight::Solr::SpellingSuggestions module
  #   - the response will have a spelling_suggestions method
  # Returns a two-element array (aka duple) with first the solr response object,
  # and second an array of SolrDocuments representing the response.docs
  def get_search_results(user_params = params || {}, extra_controller_params = {})
    solr_response = query_solr(user_params, extra_controller_params)

    case
    when (solr_response.grouped? && grouped_key_for_results)
      [solr_response.group_by(grouped_key_for_results), []]
    when (solr_response.grouped? && solr_response.grouped.length == 1)
      [solr_response.grouped.first, []]
    else
      [solr_response, solr_response.to_a]
    end
  end

  	
  # a solr query method
  # given a user query,
  # @return [Blacklight::SolrResponse] the solr response object
  def query_solr(user_params = params || {}, extra_controller_params = {})
    relation = relation_for_params(user_params.merge(extra_controller_params))
    yield relation if block_given?
    relation.load
    relation
  end
  
  # returns a params hash for finding a single solr document (CatalogController #show action)
  # If the id arg is nil, then the value is fetched from params[:id]
  # This method is primary called by the get_solr_response_for_doc_id method.
  def doc_relation(id=nil)
    id ||= params[:id]

    p = blacklight_config.default_relation.where(blacklight_config.model.primary_key => id)

    p.as!('document') unless (p.as_value)

    p
  end
  
  # a solr query method
  # retrieve a solr document, given the doc id
  # @return [Blacklight::SolrResponse, Blacklight::SolrDocument] the solr response object and the first document
  def get_solr_response_for_doc_id(id=nil, extra_controller_params=[])
    relation = extra_controller_params.inject(doc_relation(id)) {|memo, method| send(method, memo, {})}
    solr_response = find(blacklight_config.document_solr_request_handler, solr_params)
    raise Blacklight::Exceptions::InvalidSolrID.new if solr_response.to_a.empty?
    [solr_response, solr_response.to_a.first]
  end
  
  def get_solr_response_for_document_ids(ids=[], extra_solr_params = {})
    get_solr_response_for_field_values(blacklight_config.solr_document_model.unique_key, ids, extra_solr_params)
  end
  
  # given a field name and array of values, get the matching SOLR documents
  # @return [Blacklight::SolrResponse, Array<Blacklight::SolrDocument>] the solr response object and a list of solr documents
  def get_solr_response_for_field_values(field, values, extra_solr_params = [])
    relation = relation_for_params(extra_solr_params)
    values = Array(values) unless values.respond_to? :each

    if values.empty?
      # "NOT *:*"
      relation.where!.not(Arel.star => Arel.star)
    else
      relation = relation.where(field => values.first)
      if values[1]
        # "#{field}:(#{ values.to_a.map { |x| solr_param_quote(x)}.join(" OR ")})"
        values[1..-1].inject(relation) {|rel, val| rel.where.or(val)}
      end
    end

    relation.tap do |rel|
      rel.defType!("lucene") # need boolean for OR
      # not sure why fl * is neccesary, why isn't default solr_search_params
      # sufficient, like it is for any other search results solr request? 
      # But tests fail without this. I think because some functionality requires
      # this to actually get solr_doc_params, not solr_search_params. Confused
      # semantics again. 
      rel.select!(Arel.star)
      rel.unscope(:facet)
      rel.unscope(:spellcheck)
    end
    
    solr_response = relation.load
    [solr_response,relation.to_a]
  end

  def facet_opts_for(expr, relation)
    matches = relation.facet_values.select {|f| f.expr.to_s.eql(expr.to_s)}
    matches.inject({}) {|m,f| m.merge!(f.opts)}
  end

  def default_facet_opts(relation=nil)
    relation ||= blacklight_config.default_relation
    facet_opts_for(Arel.star, relation)
  end

  # returns a params hash for a single facet field solr query.
  # used primary by the get_facet_pagination method.
  # Looks up Facet Paginator request params from current request
  # params to figure out sort and offset.
  # Default limit for facet list can be specified by defining a controller
  # method facet_list_limit, otherwise 20. 
  def facet_on(facet_field, user_params=params || {}, extra_controller_params=[])
    input = user_params #.deep_merge(extra_controller_params)
    facet_config = blacklight_config.facet_fields[facet_field]

    # First start with a standard solr search params calculations,
    # for any search context in our request params. 
    relation = relation_for_params(user_params.merge(extra_controller_params))
    
    if respond_to?(:facet_list_limit)
      limit = facet_list_limit.to_s.to_i
    elsif (default_limit = default_facet_opts[:limit]) 
      limit = default_limit.to_i
    else
      limit = 20
    end
    facet_opts = {limit: limit}
    facet_opts[:offset] = ( input.fetch(Blacklight::Solr::FacetPaginator.request_keys[:page] , 1).to_i - 1 ) * ( limit )
    if  input[  Blacklight::Solr::FacetPaginator.request_keys[:sort] ]
      facet_opts[:sort] = input[  Blacklight::Solr::FacetPaginator.request_keys[:sort] ]
    end

    return relation.facet(facet_field, facet_opts).limit(0)
  end
  
  ##
  # Get the solr response when retrieving only a single facet field
  # @return [Blacklight::SolrResponse] the solr response
  def get_facet_field_response(facet_field, user_params = params || {}, extra_controller_params = [])
    relation = facet_on(facet_field, user_params, extra_controller_params)
    # Make the solr call
    relation.load
    relation
  end

  # a solr query method
  # used to paginate through a single facet field's values
  # /catalog/facet/language_facet
  def get_facet_pagination(facet_field, user_params=params || {}, extra_controller_params={})
    # Make the solr call
    response = get_facet_field_response(facet_field, user_params, extra_controller_params)

    limit = response.facets[:"f.#{facet_field}.facet.limit"].to_s.to_i - 1

    # Actually create the paginator!
    # NOTE: The sniffing of the proper sort from the solr response is not
    # currently tested for, tricky to figure out how to test, since the
    # default setup we test against doesn't use this feature. 
    return     Blacklight::Solr::FacetPaginator.new(response.facets.first.items, 
      :offset => response.params[:"f.#{facet_field}.facet.offset"], 
      :limit => limit,
      :sort => response.params[:"f.#{facet_field}.facet.sort"] || response.params["facet.sort"]
    )
  end
  deprecation_deprecate :get_facet_pagination
  
  # a solr query method
  # this is used when selecting a search result: we have a query and a 
  # position in the search results and possibly some facets
  # Pass in an index where 1 is the first document in the list, and
  # the Blacklight app-level request params that define the search. 
  # @return [Blacklight::SolrDocument, nil] the found document or nil if not found
  def get_single_doc_via_search(index, request_params)
    relation = relation_for_params(request_params)

    relation.offset(index - 1) # start at 0 to get 1st doc, 1 to get 2nd.    
    relation.limit(1)
    relation.select('*')
    relation.load
    relation.to_a.first
  end
  deprecation_deprecate :get_single_doc_via_search

  # Get the previous and next document from a search result
  # @return [Blacklight::SolrResponse, Array<Blacklight::SolrDocument>] the solr response and a list of the first and last document
  def get_previous_and_next_documents_for_search(index, request_params, extra_controller_params={})

    relation = relation_for_params(request_params.merge(extra_controller_params))

    if index > 0
      relation.offset(index - 1) # get one before
      relation.limit(3) # and one after
    else
      relation.offset(0) # there is no previous doc
      relation.limit(2) # but there should be one after
    end

    relation.select('*')
    relation.unscope(:facet)
    relation.load

    document_list = relation.to_a

    # only get the previous doc if there is one
    prev_doc = document_list.first if index > 0
    next_doc = document_list.last if (index + 1) < relation.count

    [relation, [prev_doc, next_doc]]
  end
    
  # returns a solr params hash
  # the :fl (solr param) is set to the "field" value.
  # per_page is set to 10
  def solr_opensearch_params(field=nil)
    solr_params = relation_for_params
    solr_params[:per_page] = 10
    solr_params[:fl] = field || blacklight_config.view_config('opensearch').title_field
    solr_params
  end
  
  # a solr query method
  # does a standard search but returns a simplified object.
  # an array is returned, the first item is the query string,
  # the second item is an other array. This second array contains
  # all of the field values for each of the documents...
  # where the field is the "field" argument passed in.
  def get_opensearch_response(field=nil, extra_controller_params={})
    solr_params = solr_opensearch_params().merge(extra_controller_params)
    response = find(solr_params)
    a = [solr_params[:q]]
    a << response.documents.map {|doc| doc[solr_params[:fl]].to_s }
  end
  
  # Look up facet limit for given facet_field. Will look at config, and
  # if config is 'true' will look up from Solr @response if available. If
  # no limit is avaialble, returns nil. Used from #relation_for_params
  # to supply f.fieldname.facet.limit values in solr request (no @response
  # available), and used in display (with @response available) to create
  # a facet paginator with the right limit. 
  def facet_limit_for(facet_field)
    facet = blacklight_config.facet_fields[facet_field]
    return if facet.blank?

    if facet.limit and @response and @response.facet_by_field_name(facet_field)
      limit = @response.facet_by_field_name(facet_field).limit

      if limit.nil? # we didn't get or a set a limit, so infer one.
        facet.limit if facet.limit != true
      elsif limit == -1 # limit -1 is solr-speak for unlimited
        nil
      else
        limit.to_i - 1 # we added 1 to find out if we needed to paginate
      end
    elsif facet.limit
      facet.limit == true ? DEFAULT_FACET_LIMIT : facet.limit
    end
  end

  ##
  # The key to use to retrieve the grouped field to display 
  def grouped_key_for_results
    blacklight_config.index.group
  end

  def blacklight_solr
    @solr ||=  RSolr.connect(blacklight_solr_config)
  end

  def blacklight_solr_config
    Blacklight.solr_config
  end

  private

  def should_add_to_solr field_name, field
    field.include_in_request || (field.include_in_request.nil? && blacklight_config.add_field_configuration_to_solr_request)
  end

end
