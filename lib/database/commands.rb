require "set"
require "uri"
require "json"
require "net/http"
require "utilities/json"
require "database/auth"
require "database/exceptions"
require "documents/document_query"
require "requests/request_helpers"

module RavenDB
  class RavenCommand
    def initialize(end_point, method = Net::HTTP::Get::METHOD, params = {}, payload = nil, headers = {})
      @end_point = end_point || ""
      @method = method
      @params = params
      @payload = payload
      @headers = headers
      @failed_nodes = Set.new([])  
      @_last_response = nil      
    end

    def server_response
      @_last_response
    end  

    def was_failed?()
      !@failed_nodes.empty?
    end

    def add_failed_node(node)
      assert_node(node)
      @failed_nodes.add(node)
    end

    def was_failed_with_node?(node)
      assert_node(node)
      @failed_nodes.include?(node)
    end

    def create_request(server_node)
      raise NotImplementedError, "You should implement create_request method"
    end  

    def to_request_options
      end_point = @end_point

      if !@params.empty?        
        encoded_params = URI.encode_www_form(@params)
        end_point = "#{end_point}?#{encoded_params}"
      end

      requestCtor = Object.const_get("Net::HTTP::#{@method.capitalize}")
      request = requestCtor.new(end_point)

      if !@payload.nil? && !@payload.empty?
        request.body = JSON.generate(@payload)
        @headers['Content-Type'] = 'application/json'
      end 
      
      if !@headers.empty?      
        @headers.each do |header, value|
          request.add_field(header, value)
        end
      end  

      request
    end  

    def set_response(response)
      @_last_response = response

      if @_last_response
        ExceptionsRaiser.try_raise_from(response)
        return response.json
      end   
    end  

    protected
    def assert_node(node)
      raise ArgumentError, "Argument \"node\" should be an instance of ServerNode" unless node.is_a? ServerNode
    end

    def add_params(param_or_params, value)      
      new_params = param_or_params

      if !new_params.is_a?(Hash)
        new_params = Hash.new
        new_params[param_or_params] = value
      end    

      @params = @params.merge(new_params)
    end

    def remove_params(param_or_params, *other_params)
      remove = param_or_params

      if !remove.is_a?(Array)
        remove = [remove]
      end  

      if !other_params.empty?        
        remove = remove.concat(other_params)
      end

      remove.each {|param| @params.delete(param)}
    end  
  end  

  class BatchCommand < RavenCommand
    def initialize(commands_array = [])
      super("", Net::HTTP::Post::METHOD)
      @commands_array = commands_array
    end

    def create_request(server_node)
      commands = @commands_array
      assert_node(server_node)

      if !commands.all? { |data| data && data.is_a?(RavenCommandData) }
        raise InvalidOperationException, "Not a valid command"
      end

      @end_point = "/databases/#{server_node.database}/bulk_docs"
      @payload = {"Commands" => commands.map { |data| data.to_json }}
    end

    def set_response(response)
      result = super(response)

      if !response.body
        raise InvalidOperationException, "Invalid response body received"
      end

      result["Results"]
    end
  end

  class CreateDatabaseCommand < RavenCommand
    def initialize(database_document, replication_factor = 1)
      super("", Net::HTTP::Put::METHOD)
      @database_document = database_document || nil
      @replication_factor = replication_factor || 1
    end

    def create_request(server_node)
      db_name = @database_document.database_id.gsub("Raven/Databases/", "")
      assert_node(server_node)

      if db_name.nil? || !db_name
        raise InvalidOperationException, "Empty name is not valid"
      end

      if /^[A-Za-z0-9_\-\.]+$/.match(db_name).nil?
        raise InvalidOperationException, "Database name can only contain only A-Z, a-z, \"_\", \".\" or \"-\""
      end

      if !@database_document.settings.key?("Raven/DataDir") 
        raise InvalidOperationException, "The Raven/DataDir setting is mandatory"
      end

      @params = {"name" => db_name, "replication-factor" => @replication_factor}
      @end_point = "/admin/databases"
      @payload = @database_document.to_json
    end

    def set_response(response)
      result = super(response)

      if !response.body
        raise ErrorResponseException, "Response is invalid."
      end

      result
    end
  end

  class QueryBasedCommand < RavenCommand
    def initialize(method, query, options = nil)
      super("", method)
      @query = query || nil
      @options = options || QueryOperationOptions.new
    end

    def create_request(server_node)
      assert_node(server_node)
      query = @query
      options = @options

      if !query.is_a?(IndexQuery)
        raise InvalidOperationException, "Query must be instance of IndexQuery class"
      end

      if !options.is_a?(QueryOperationOptions)
        raise InvalidOperationException, "Options must be instance of QueryOperationOptions class"
      end

      @params = {
        "allowStale" => options.allow_stale,
        "details" => options.retrieve_details,
        "maxOpsPerSec" => options.max_ops_per_sec
      }

      @end_point = "/databases/#{server_node.database}/queries"
      
      if options.stale_timeout
        add_params("staleTimeout", options.stale_timeout)
      end  
    end
  end

  class DeleteByQueryCommand < QueryBasedCommand
    def initialize(query, options = nil)
      super(Net::HTTP::Delete::METHOD, query, options)
    end

    def create_request(server_node)
      super(server_node)
      @payload = @query.to_json
    end

    def set_response(response)
      result = super(response)

      if !response.body
        raise IndexDoesNotExistException, "Could not find index"
      end

      result
    end
  end

  class DeleteDatabaseCommand < RavenCommand
    def initialize(database_id, hard_delete = false, from_node = nil)
      super("", Net::HTTP::Delete::METHOD)
      @from_node = from_node
      @database_id = database_id
      @hard_delete = hard_delete
    end

    def create_request(server_node)
      db_name = @database_id.gsub("Raven/Databases/", "")
      @params = {"name" => db_name}
      @end_point = "/admin/databases"

      if @hard_delete
        add_params("hard-delete", "true")
      end

      if @from_node
        add_params("from-node",  @from_node.cluster_tag)
      end      
    end
  end

  class DeleteDocumentCommand < RavenCommand
    def initialize(id, change_vector = nil)
      super("", Net::HTTP::Delete::METHOD)

      @id = id || nil;
      @change_vector = change_vector
    end

    def create_request(server_node)
      assert_node(server_node)

      if !@id
        raise InvalidOperationException, "Nil Id is not valid"
      end

      if !@id.is_a?(String)
        raise InvalidOperationException, "Id must be a string"
      end

      if @change_vector
        @headers = {"If-Match" => "\"#{@change_vector}\""}
      end

      @params = {"id" => @id}
      @end_point = "/databases/#{server_node.database}/docs"
    end

    def set_response(response)
      super(response)
      check_response(response)
    end

    protected 
    def check_response(response)
      if !response.is_a?(Net::HTTPNoContent)
        raise InvalidOperationException, "Could not delete document #{@id}"
      end
    end
  end  

  class DeleteIndexCommand < RavenCommand
    def initialize(index_name)
      super("", Net::HTTP::Delete::METHOD)
      @index_name = index_name || nil
    end

    def create_request(server_node)
      assert_node(server_node)

      if !@index_name
        raise InvalidOperationException, "nil or empty index_name is invalid"
      end

      @params = {"name" => @index_name}
      @end_point = "/databases/#{server_node.database}/indexes"
    end
  end

  class GetApiKeyCommand < RavenCommand
    def initialize(name)
      super("", Net::HTTP::Get::METHOD)

      if !name
        raise InvalidOperationException, "Api key name isn't set"
      end

      @name = name || nil
    end

    def create_request(server_node)
      assert_node(server_node)
      @params = {"name" => @name}
      @end_point = "/admin/api-keys"
    end

    def set_response(response)
      result = super(response)
      
      if result && result["Results"]
        return result["Results"]
      end

      raise ErrorResponseException, "Invalid server response"
    end
  end

  class GetTopologyCommand < RavenCommand
    def initialize(force_url = nil)
      super("", Net::HTTP::Get::METHOD)
      @force_url = force_url
    end

    def create_request(server_node)
      assert_node(server_node)
      @params = {"name" => server_node.database}
      @end_point = "/topology"

      if @force_url
        add_params("url", @force_url)
      end        
    end

    def set_response(response)
      result = super(response)

      if response.body && response.is_a?(Net::HTTPOK)
        return result
      end
    end
  end

  class GetClusterTopologyCommand < GetTopologyCommand
    def create_request(server_node)
      super(server_node)
      remove_params("name")
      @end_point = "/cluster/topology"
    end
  end

  class GetDocumentCommand < RavenCommand
    def initialize(id_or_ids, includes = nil, metadata_only = false)
      super("", Net::HTTP::Get::METHOD, nil, nil, {});

      @id_or_ids = id_or_ids || []
      @includes = includes
      @metadata_only = metadata_only
    end

    def create_request(server_node)
      assert_node(server_node)

      if !@id_or_ids
        raise InvalidOperationException, "nil ID is not valid"
      end
      
      ids = @id_or_ids.is_a?(Array) ? @id_or_ids : [@id_or_ids]
      first_id = ids.first
      multi_load = ids.size > 1 

      @params = {}
      @end_point = "/databases/#{server_node.database}/docs"
      
      if @includes
        add_params("include", @includes)
      end        
      
      if multi_load
        if @metadata_only
          add_params("metadata-only", "True")
        end  

        if (ids.map { |id| id.size }).sum > 1024
          @payload = {"Ids" => ids}
          @method = Net::HTTP::Post::METHOD          
        end
      end

      add_params("id", multi_load ? ids : first_id);
    end

    def set_response(response)
      result = super(response);   

      if response.is_a?(Net::HTTPNotFound)
        return;
      end

      if !response.body
        raise ErrorResponseException, "Failed to load document from the database "\
  "please check the connection to the server"
      end

      result
    end
  end

  class GetIndexesCommand < RavenCommand
    def initialize(start = 0, page_size = 10)
      super("", Net::HTTP::Get::METHOD, nil, nil, {})
      @start = start
      @page_size = page_size
    end

    def create_request(server_node)
      assert_node(server_node)
      @end_point = "/databases/#{server_node.database}/indexes"
      @params = { "start" => @start, "page_size" => @page_size }
    end

    def set_response(response)
      result = super(response)

      if response.is_a?(Net::HTTPNotFound)
        raise IndexDoesNotExistException, "Can't find requested index(es)"
      end

      if !response.body
        return;
      end

      result["Results"]
    end
  end

  class GetIndexCommand < GetIndexesCommand
    def initialize(index_name)
      super()
      @index_name = index_name || nil
    end

    def create_request(server_node)
      super(server_node)
      @params = {"name" => @index_name}
    end

    def set_response(response)
      results = super(response)

      if results.is_a?(Array)
        return results.first
      end
    end
  end

  class GetOperationStateCommand < RavenCommand
    def initialize(id)
      super("", Net::HTTP::Get::METHOD)
      @id = id || nil
    end

    def create_request(server_node)
      assert_node(server_node)
      @params = {"id" => @id}
      @end_point = "/databases/#{server_node.database}/operations/state"
    end

    def set_response(response)
      result = super(response)

      if response.body
        return result
      end

      raise ErrorResponseException, "Invalid server response"
    end
  end

  class GetStatisticsCommand < RavenCommand
    def initialize(check_for_failures = false)
      super("", Net::HTTP::Get::METHOD)
      @check_for_failures = check_for_failures
    end

    def create_request(server_node)
      assert_node(server_node)
      @end_point = "/databases/#{server_node.database}/stats"
      
      if @check_for_failures
        add_params("failure", "check")
      end  
    end

    def set_response(response)
      result = super(response)

      if response.is_a?(Net::HTTPOK) && response.body
        return result
      end    
    end
  end

  class PatchByQueryCommand < QueryBasedCommand
    def initialize(query_to_update, patch = nil, options = nil)
      super(Net::HTTP::Patch::METHOD, query_to_update, options)
      @patch = patch
    end

    def create_request(server_node)
      super(server_node)

      if !@patch.is_a?(PatchRequest)
        raise InvalidOperationException, "Patch must be instanceof PatchRequest class"
      end

      @payload = {
        "Patch" => @patch.to_json,
        "Query" => @query.to_json,
      }            
    end

    def set_response(response)
      result = super(response)

      if !response.body
        raise IndexDoesNotExistException, "Could not find index"
      end

      if !response.is_a?(Net::HTTPOK) && !response.is_a?(Net::HTTPAccepted)
        raise ErrorResponseException, "Invalid response from server"
      end

      result
    end
  end

  class PatchCommand < RavenCommand
    def initialize(id, patch, options = nil)
      super('', Net::HTTP::Patch::METHOD)
      opts = options || {}

      @id = id || nil
      @patch = patch || nil
      @change_vector = opts["change_vector"] || nil
      @patch_if_missing = opts["patch_if_missing"] || nil
      @skip_patch_if_change_vector_mismatch = opts["skip_patch_if_change_vector_mismatch"] || false
      @return_debug_information = opts["return_debug_information"] || false
    end

    def create_request(server_node)
      assert_node(server_node)

      if @id.nil?
        raise InvalidOperationException, 'Empty ID is invalid'
      end

      if @patch.nil?
        raise InvalidOperationException, 'Empty patch is invalid'
      end

      if @patch_if_missing && !@patch_if_missing.script
        raise InvalidOperationException, 'Empty script is invalid'
      end

      @params = {"id" => @id}
      @end_point = "/databases/#{server_node.database}/docs"

      if @skip_patch_if_change_vector_mismatch
        add_params('skipPatchIfChangeVectorMismatch', 'true')
      end  

      if @return_debug_information
        add_params('debug', 'true')
      end  

      if !@change_vector.nil?
        @headers = {"If-Match" => "\"#{@change_vector}\""}
      end  

      @payload = {
        "Patch" => @patch.to_json,
        "PatchIfMissing" => @patch_if_missing ? @patch_if_missing.to_json : nil
      }
    end

    def set_response(response)
      result = super(response)

      if !response.is_a?(Net::HTTPOK) && !response.is_a?(Net::HTTPNotModified)
        raise InvalidOperationException, "Could not patch document #{@id}"
      end

      if response.body
        return result
      end
    end
  end

  class PutApiKeyCommand < RavenCommand
    def initialize(name, api_key)
      super('', Net::HTTP::Put::METHOD)

      if !name
        raise InvalidOperationException, 'Api key name isn\'t set'
      end

      if !api_key
        raise InvalidOperationException, 'Api key definition isn\'t set'
      end

      if !api_key.is_a?(ApiKeyDefinition)
        raise InvalidOperationException, 'Api key definition mus be an instance of ApiKeyDefinition'
      end

      @name = name
      @api_key = api_key
    end

    def create_request(server_node)
      assert_node(server_node)

      @params = {"name" => @name}
      @payload = @api_key.to_json
      @end_point = "/admin/api-keys"
    end
  end

  class PutDocumentCommand < DeleteDocumentCommand
    def initialize(id, document, change_vector = nil)
      super(id, change_vector)

      @document = document || nil
      @method = Net::HTTP::Put::METHOD
    end

    def create_request(server_node)
      if !@document
        raise InvalidOperationException, 'Document must be an object'
      end

      @payload = @document;
      super(server_node);
    end

    def set_response(response)
      super(response)
      return response.body
    end

    protected
    def check_response(response)
      if !response.body
        raise ErrorResponseException, "Failed to store document to the database "\
  "please check the connection to the server"
      end
    end
  end

  class PutIndexesCommand < RavenCommand
    def initialize(indexes_to_add, *more_indexes_to_add)
      @indexes = []
      indexes = indexes_to_add.is_a?(Array) ? indexes_to_add : [indexes_to_add]

      if more_indexes_to_add.is_a?(Array) && !more_indexes_to_add.empty?
        indexes = indexes.concat(more_indexes_to_add)
      end
      
      super('', Net::HTTP::Put::METHOD)

      if indexes.empty?
        raise InvalidOperationException, 'No indexes specified'
      end

      indexes.each do |index|
        if !index.is_a?(IndexDefinition)
          raise InvalidOperationException, 'All indexes should be instances of IndexDefinition'
        end

        if !index.name
          raise InvalidOperationException, 'All indexes should have a name'
        end

        @indexes.push(index)
      end
    end

    def create_request(server_node)
      assert_node(server_node)
      @end_point = "/databases/#{server_node.database}/indexes"
      @payload = {"Indexes" => @indexes.map { |index| index.to_json }}
    end

    def set_response(response)
      result = super(response)

      if !response.body
        throw raise ErrorResponseException, "Failed to put indexes to the database "\
  "please check the connection to the server"
      end
      
      result
    end
  end

  class QueryCommand < RavenCommand
    def initialize(index_query, conventions, metadata_only = false, index_entries_only = false)
      super('', Net::HTTP::Post::METHOD, nil, nil, {})

      if !index_query.is_a?(IndexQuery)
        raise InvalidOperationException, 'Query must be an instance of IndexQuery class'
      end

      if !conventions
        raise InvalidOperationException, 'Document conventions cannot be empty'
      end

      @index_query = index_query || nil
      @conventions = conventions || nil
      @metadata_only = metadata_only
      @index_entries_only = index_entries_only
    end

    def create_request(server_node)
      assert_node(server_node)

      @end_point = "/databases/#{server_node.database}/queries"
      @params = {"query-hash" => @index_query.query_hash}

      if @metadata_only 
        add_params('metadata-only', 'true')
      end

      if @index_entries_only
        add_params('debug', 'entries')
      end
      
      @payload = @index_query.to_json
    end

    def set_response(response)
      result = super(response)

      if !response.body
        raise IndexDoesNotExistException, "Could not find index"
      end

      result
    end
  end

  class RavenCommandData
    def initialize(id, change_vector)
      @id = id
      @change_vector = change_vector || nil;
      @type = nil
    end

    def document_id
      @id
    end

    def to_json
      return {
        "Type" => @type,
        "Id" => @id,
        "ChangeVector" => @change_vector
      }
    end
  end

  class DeleteCommandData < RavenCommandData
    def initialize(id, change_vector = nil)
      super(id, change_vector)
      @type = Net::HTTP::Delete::METHOD
    end
  end

  class PatchCommandData < RavenCommandData
    def initialize(id, scripted_patch, change_vector = nil, patch_if_missing = nil, debug_mode = nil)
      super(id, change_vector)

      @type = Net::HTTP::Patch::METHOD
      @scripted_patch = scripted_patch || nil
      @patch_if_missing = patch_if_missing
      @debug_mode = debug_mode
      @additional_data = nil
    end

    def to_json
      json = super().merge({
        "Patch" => @scripted_patch.to_json,
        "DebugMode" => @debug_mode
      })
            
      if !@patch_if_missing.nil?
        json["PatchIfMissing"] = @patch_if_missing.to_json
      end

      return json
    end
  end

  class PutCommandData < RavenCommandData
    def initialize(id, document, change_vector = nil, metadata = nil)
      super(id, change_vector)

      @type = Net::HTTP::Put::METHOD
      @document = document || nil
      @metadata = metadata
    end

    def to_json
      json = super()
      document = @document

      if @metadata
        document["@metadata"] = @metadata
      end

      json["Document"] = document
      return json
    end
  end

  class SaveChangesData
    def deferred_commands_count
      @deferred_command_count
    end

    def commands_count
      @commands.size
    end

    def initialize(commands = nil, deferred_command_count = 0, documents = nil)
      @commands = commands || []
      @documents = documents || []
      @deferred_commands_count = deferred_command_count
    end        

    def add_command(command)
      @commands.push(command)
    end

    def add_document(document)
      @documents.push(document)
    end

    def get_document(index)
      @documents.at(index)
    end

    def create_batch_command
      BatchCommand.new(@commands)
    end
  end
end