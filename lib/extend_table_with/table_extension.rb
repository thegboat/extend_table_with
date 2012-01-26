module ActiveRecord
  class TableExtension
  
    def initialize(parent, association, options = {})
      @name         = association.to_sym
      @readonly     = !!options[:accessor_readonly]
      @serialize    = options[:serialize].nil? ? true : !!options[:serialize]
      @exceptions   = options[:except].to_a.collect(&:to_s)
      @parent       = parent
    end
  
    def reflection
      @parent.reflect_on_association(name)
    end
  
    def foreign_key
      reflection.options[:foreign_key] || reflection.active_record.to_s.foreign_key
    end
  
    #when true extended attributes will be added to parents serialize methods
    def serialized
      @serialize ? extended.collect(&:to_sym) : []
    end
  
    def name
      @name
    end
  
    #no setters will be created for the extension when true
    def readonly
      @readonly
    end
    
    def will_respond_to?(method)
      klass.new.respond_to?(method)
    end
    
    #user declared exceptions ... exclude these attributes calls from parent
    def exceptions
      @exceptions
    end
    
    #exclude for both sql and attribute calls
    def exclude_always
      ['id','created_at','updated_at','deleted_at', 'type', foreign_key] 
    end
  
    #we want to omit these columns
    def exclude
      exceptions | exclude_always
    end
  
    def klass
      @parent.reflect_on_association(name.to_sym).klass
    end
  
    def table
      klass.table_name
    end
  
    def columns
      klass.column_names
    end
    
    #the table columns that will be extended in sql
    def extended_with_exceptions
      columns - (@parent.column_names | exclude_always)
    end
  
    #the attributes that will be extended
    def extended
      columns - (@parent.column_names | exclude)
    end
  
    #the parent has a column of same name/ keep them in sync
    def mirrored
      @parent.column_names & (columns - exclude)
    end
  
    def join_sql
      "#{@parent.table_name}.id = #{table}.#{foreign_key}"
    end
  end
end