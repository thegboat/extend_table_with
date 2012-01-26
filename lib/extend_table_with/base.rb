module ActiveRecord
  class Base
    
    class << self
      def extend_table_with_options
        #accessor_readonly => not false will prevent setter methods from being created
        #except => (list of symbols), represents what attributes will not be extended
        #serialize => extended attributes with parent serialization when the value is not explicitly false
        [:accessor_readonly, :except, :serialize]
      end

      #interface method
      def extend_table_with(association,options)
        options.symbolize_keys!
        @table_extensions ||= (superclass.table_extended_with.dup rescue [])
        has_one(association, options.except(*extend_table_with_options) )
        @table_extension = add_extension(association,options)
        revise_table
        true
      end
      
      def extended?
        !table_extended_with.empty?
      end

      def extended_class
        if extended?
          create_extension_view_and_class && const_get("Extended#{to_s}")
        else
          nil
        end
      end
      alias :define_extended_class :extended_class

      def extended_table_columns
        extended? ? extended_class.column_names : []
      end
      
      def extended_default_select_columns
        column_names.collect {|n| "#{extended_table_name}.#{n}"}
      end

      #provides a finder that treats association columns as the targets own
      def find_on_extension(*args)
        if extended?
          define_extended_class
          finder_type, options = args.first, args.extract_options!
          options = prepare_extended_options(options, finder_type)
          sql = construct_finder_sql(options)
          sql = replace_tables_text(sql)
          result = find_by_sql(sql)
          preload_associations(result, options[:include]) if options[:include]
          [:first,:last].include?(finder_type) ? result.first : result
        else
          find(*args)
        end
      end

      def paginate_on_extension(*args)
        if extended?
          define_extended_class
          options = prepare_extended_options(args.pop)
          sql = construct_finder_sql(options)
          sql = replace_tables_text(sql)
          result = if connection.adapter_name =~ /^mysql/i
            pager = WillPaginate::Collection.new(*wp_parse_options(options))
            add_limit!(sql, :offset => pager.offset, :limit => pager.per_page)
            sql.gsub!(/^SELECT /i,"SELECT SQL_CALC_FOUND_ROWS ")
            presult = find_by_sql(sql)
            pager.total_entries = connection.select_value("SELECT FOUND_ROWS()")
            pager.replace(presult)
          else
            paginate_by_sql(sql, options)
          end  
          preload_associations(result, options[:include]) if options[:include]
          result
        else
          paginate(args.pop)
        end
      end

      def update_on_extension(set,where = nil)
        if extended?
          update_counts = 0
          set_clauses  = build_extended_set_clauses(set)
          where_clause = replace_tables_text(sanitize_sql_for_conditions(where))
          transaction do
            update_counts = set_clauses.keys.collect do |s|
              extended_class.update_all(set_clauses[s],where_clause)
            end
          end
          update_counts.max.to_i
        end
      end

      def table_extended_with
        @table_extensions.to_a
      end
      
      def extended_with_tables
        table_extended_with.collect(&:table)
      end

      def extended_table_name
        "extended_#{to_s.tableize}" 
      end

      def serialize_options_update(options)
        unless serialize_extended_methods_builder.empty?
          update_with = (serialize_extended_methods_builder - options[:except].to_a)
          update_with &= options[:only].to_a if options[:only]
          options[:methods] = options[:methods].to_a + update_with
        end
        options
      end

      private

      #create getters and setters for the extension
      def revise_table
        name = @table_extension.name
        @table_extension.extended.each do |method_name|
          define_extension_setter(name, method_name)
          define_extension_getter(name, method_name)
          define_extension_dirty(name, method_name)
        end
        @table_extension.mirrored.each do |method_name|
          define_extension_mirror_setter(name, method_name)
        end
        true
      end

      def define_extension_setter(assoc_name,method_name)
        return if @table_extension.readonly
        define_method("#{method_name}=") do |value|
          assoc = send(assoc_name) || send("build_#{assoc_name}")
          assoc[method_name] = value  if assoc
        end
      end

      def define_extension_getter(assoc_name,method_name)
        define_method(method_name) do
          assoc = send(assoc_name) || send("build_#{assoc_name}")
          assoc[method_name] if assoc
        end
      end

      def define_extension_mirror_setter(assoc_name, method_name)
        return if @table_extension.readonly
        define_method("#{method_name}=") do |value|
          assoc = send(assoc_name) || send("build_#{assoc_name}")
          assoc[method_name] = value  if assoc
          super(value)
        end
      end
      
      def define_extension_dirty(assoc_name, method_name)
        define_method("#{method_name}_changed?") do
          assoc = send(assoc_name) || send("build_#{assoc_name}")
          assoc.send("#{method_name}_changed?") rescue false
        end
      end
      
      def prepare_extended_options(options, finder_type = nil)
        if (options.symbolize_keys.keys & [:select, :group, :order]).empty?
          options[:select] = extended_default_select_columns.join(',')
        end
        if [:first, :last].include?(finder_type)
          options.merge!(:limit => 1)
          if finder_type == :last and options[:order]
            options[:order] = reverse_sql_order(order)
          elsif finder_type == :last
            options[:order] = "#{extended_table_name}.#{primary_key} DESC"
          end
        end
        options
      end

      #clean up the table names
      def replace_tables_text(v)
        t = sanitize_sql(v)
        (table_extended_with.collect(&:table) | [table_name]).each do |cur_tab|
          t.gsub!(/(\W|\A)#{cur_tab}(\W)/i) {"#{$1}#{extended_table_name}#{$2}"}
        end
        t
      end
  
      #we are grouping the attributes that we want to update with the relevant
      #table.  We can only update a single table of the view at a time.
      #So we build a clause for each table
      def build_extended_set_clauses(set)
        set = normalize_keys(set)
        set_clauses, cols = {}, set.keys
        table_extended_with.each do |ext|
          key_cols = (ext.extended & cols)
          next if key_cols.empty?
          set_clauses[ext.table] = key_cols.collect {|col| build_set_clause(col,set[col]) }.join(', ')
          cols -= key_cols
        end
        key_cols = (column_names & cols)
        unless key_cols.empty?
          set_clauses[table_name] = key_cols.collect {|col| build_set_clause(col,set[col]) }.join(", ")
        end
        set_clauses
      end

      def build_set_clause(k,v)
        clause = ["#{k} = ?", v]
        sanitize_sql_for_conditions(clause)
      end

      def normalize_keys(set)
        Hash[*set.collect {|k,v| [k.to_s.strip.downcase, v] }.flatten ]
      end

      def serialize_extended_methods_builder
        @serialize_methods_builder ||= table_extended_with.collect(&:serialized).flatten.uniq
      end

      #add the new extension to extensions and send it back
      def add_extension(association, options)
        # if there is a already an extension with this name remove it
        @table_extensions.reject! {|ext| ext.name == association} 
        @table_extensions <<  TableExtension.new(self,association, options)
        @table_extensions.last
      end
  
      #this only works with MySQL
      def create_extension_view_and_class
        self.const_get("Extended#{to_s}")
      rescue
          clause = view_builder
          #this needs to be moved into the specific db adapter files
          connection.execute %{
            create or replace algorithm = merge SQL SECURITY DEFINER view #{extended_table_name} as select #{clause[:view_select]} from #{table_name} #{clause[:view_joins]}#{clause[:view_conditions]}
          }
          class_eval %{
          class Extended#{to_s} < #{to_s}
            set_table_name "#{extended_table_name}"
            def self.descends_from_active_record?
              true
            end
          end
          }
        true
      end

      def view_builder
        attrs, seen, joins = ["#{table_name}.*"], [], []
        table_extended_with.each do |ext|
          cols = (ext.extended_with_exceptions - seen)
          seen += cols
          attrs += cols.collect {|c| "#{ext.table}.#{c}"}
          joins << "INNER JOIN #{ext.table} ON #{ext.join_sql}"
        end
        subclass_tables = (extended_with_tables | subclasses.collect(&:extended_with_tables).flatten)
        if finder_needs_type_condition?
          conditions = " where #{table_name}.type = '#{to_s}'"
        elsif not column_names.include?('type')
          attrs << "'#{to_s}' as type"
          conditions = nil
        end
        { :view_select => attrs.join(','), :view_joins => joins.join("\n"), :view_conditions => conditions }
      end
      
      def type_condition(table_alias=nil)
        quoted_table_alias = self.connection.quote_table_name(table_alias || table_name)
        quoted_inheritance_column = connection.quote_column_name(inheritance_column)
        type_condition = subclasses.inject("#{quoted_table_alias}.#{quoted_inheritance_column} = '#{sti_name}' ") do |condition, subclass|
          if subclass.sti_name != "#{to_s}::Extended#{to_s}"
            condition << "OR #{quoted_table_alias}.#{quoted_inheritance_column} = '#{subclass.sti_name}' " 
          else
            condition
          end
        end

        " (#{type_condition}) "
      end
    end
  
    #the instance should serialize the extended attributes as if they were its own
    def to_json(options = {})
      super(self.class.serialize_options_update(options))
    end

    def to_xml(options = {})
      super(self.class.serialize_options_update(options))
    end
    
    def extensions_changed?
      self.class.table_extended_with.any? {|ext| send(ext.name).changed? rescue false }
    end
    
    def changed?
      super or extensions_changed?
    end

    #earlier versions of rails may need this here ... namely 2.3.4
    if RAILS_GEM_VERSION < '2.3.8'
      def attributes=(new_attributes, guard_protected_attributes = true)
        return if new_attributes.nil?
        attributes = new_attributes.dup
        attributes.stringify_keys!

        multi_parameter_attributes = []
        attributes = remove_attributes_protected_from_mass_assignment(attributes) if guard_protected_attributes

        attributes.each do |k, v|
          if k.include?("(")
            multi_parameter_attributes << [ k, v ]
          else
            respond_to?(:"#{k}=") ? send(:"#{k}=", v) : raise(UnknownAttributeError, "unknown attribute: #{k}")
          end
        end

        assign_multiparameter_attributes(multi_parameter_attributes)
      end
    end
  end
end