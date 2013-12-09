module Fluent
  class MysqlReplicatorMultiInput < Fluent::Input
    Plugin.register_input('mysql_replicator_multi', self)

    def initialize
      require 'mysql2'
      require 'digest/sha1'
      super
    end

    config_param :manager_host, :string, :default => 'localhost'
    config_param :manager_port, :integer, :default => 3306
    config_param :manager_username, :string, :default => nil
    config_param :manager_password, :string, :default => ''
    config_param :manager_database, :string, :default => 'replicator_manager'

    def configure(conf)
      super
      @reconnect_interval = Config.time_value('10sec')
    end

    def start
      begin
        @manager_db = get_manager_connection
        @threads = []
        get_config.each do |config|
          @threads << Thread.new {
            poll(config)
          }
        end
        $log.error "mysql_replicator_multi: stop working due to empty configuration" if @threads.empty?
      rescue StandardError => e
        $log.error "error: #{e.message}"
        $log.error e.backtrace.join("\n")
      end
    end

    def shutdown
      @threads.each do |thread|
        Thread.kill(thread)
      end
    end

    def get_config
      configs = []
      query = "SELECT * FROM source"
      @manager_db.query(query).each do |row|
        configs << row
      end
      return configs
    end

    def poll(config)
      begin
        masked_config = config.map {|k,v| (k == 'password') ? v.to_s.gsub(/./, '*') : v}
        $log.info "mysql_replicator_multi: polling start. :config=>#{masked_config}"
        primary_key = config['primary_key']
        previous_id = current_id = 0
        loop do
          db = get_source_connection(config)
          db.query(config['query']).each do |row|
            current_id = row[primary_key]
            detect_insert_update(config, row)
            detect_delete(config, current_id, previous_id)
            previous_id = current_id
          end
          db.close
          sleep config['interval']
        end
      rescue StandardError => e
        $log.error "error: #{e.message}"
        $log.error e.backtrace.join("\n")
      end
    end

    def detect_insert_update(config, row)
      primary_key = config['primary_key']
      current_id = row[primary_key]
      stored_hash = get_stored_hash(config['name'], current_id)
      current_hash = Digest::SHA1.hexdigest(row.flatten.join)

      event = nil
      if stored_hash.empty?
        event = :insert
      elsif stored_hash != current_hash
        event = :update
      end
      unless event.nil?
        emit_record("#{config['tag']}.#{event.to_s}", row)
        update_hashmap({:event => event, :ids => current_id, :source_name => config['name'], :hash => current_hash})
      end
    end

    def get_stored_hash(source_name, id)
      query = "SELECT source_query_hash FROM hashmap WHERE source_query_pk = #{id.to_i} AND source_name = '#{source_name}'"
      @manager_db.query(query).each do |row|
        return row['source_query_hash']
      end
    end

    def detect_delete(config, current_id, previous_id)
      return unless config['enable_delete'] == 1
      deleted_ids = collect_gap_ids(config['name'], current_id, previous_id)
      unless deleted_ids.empty?
        event = :delete
        deleted_ids.each do |id|
          emit_record("#{config['tag']}.#{event.to_s}", {config['primary_key'] => id})
        end
        update_hashmap({:event =>  event, :ids => deleted_ids, :source_name => config['name']})
      end
    end

    def collect_gap_ids(source_name, current_id, previous_id)
      if (current_id - previous_id) > 1
        query = "SELECT source_query_pk FROM replicator.hashmap 
          WHERE source_name = '#{source_name}' 
          AND source_query_pk > #{previous_id.to_i} AND source_query_pk < #{current_id.to_i}"
      elsif previous_id > current_id
        query = "SELECT source_query_pk FROM replicator.hashmap 
          WHERE source_name = '#{source_name}' 
          AND source_query_pk > #{previous_id.to_i}"
      elsif previous_id == current_id
        query = "SELECT source_query_pk FROM replicator.hashmap 
          WHERE source_name = '#{source_name}' 
          AND (source_query_pk > #{current_id.to_i} OR source_query_pk < #{current_id.to_i})"
      end
      ids = Array.new
      unless query.nil?
        @manager_db.query(query).each do |row|
          ids << row['source_query_pk']
        end
      end
      return ids
    end

    def update_hashmap(opts)
      ids = opts[:ids].is_a?(Integer) ? [opts[:ids]] : opts[:ids]
      ids.each do |id|
        case opts[:event]
        when :insert
          query = "insert into hashmap (source_name,source_query_pk,source_query_hash) values('#{opts[:source_name]}','#{id}','#{opts[:hash]}')"
        when :update
          query = "update hashmap set source_query_hash = '#{opts[:hash]}' WHERE source_name = '#{opts[:source_name]}' AND source_query_pk = '#{id}'"
        when :delete
          query = "delete from hashmap WHERE source_name = '#{opts[:source_name]}' AND source_query_pk = '#{id}'"
        end
        p query
        @manager_db.query(query) unless query.nil?
      end
    end

    def emit_record(tag, record)
      Engine.emit(tag, Engine.now, record)
    end

    def get_manager_connection
      begin
        return Mysql2::Client.new(
          :host => @manager_host,
          :port => @manager_port,
          :username => @manager_username,
          :password => @manager_password,
          :database => @manager_database,
          :encoding => 'utf8',
          :reconnect => true,
          :stream => false,
          :cache_rows => false
        )
      rescue Exception => e
        $log.warn "mysql_replicator_multi: #{e}"
        sleep @reconnect_interval
        retry
      end
    end

    def get_source_connection(config)
      begin
        return Mysql2::Client.new(
          :host => config['host'],
          :port => config['manager_port'],
          :username => config['username'],
          :password => config['password'],
          :database => config['database'],
          :encoding => 'utf8',
          :reconnect => true,
          :stream => true,
          :cache_rows => false
        )
      rescue Exception => e
        $log.warn "mysql_replicator_multi: #{e}"
        sleep @reconnect_interval
        retry
      end
    end
  end
end