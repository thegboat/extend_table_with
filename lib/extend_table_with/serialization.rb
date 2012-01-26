#i had to override these because has_one serialization was not working right
module ActiveRecord
  module Serialization
    class Serializer #:nodoc:

      # Add associations specified via the <tt>:includes</tt> option.
      # Expects a block that takes as arguments:
      #   +association+ - name of the association
      #   +records+     - the association record(s) to be serialized
      #   +opts+        - options for the association records
      def add_includes(&block)
        if include_associations = options.delete(:include)
          base_only_or_except = { :except => options[:except],
                                  :only => options[:only] }

          include_has_options = include_associations.is_a?(Hash)
          associations = include_has_options ? include_associations.keys : Array(include_associations)

          for association in associations
            association_type = @record.class.reflect_on_association(association).macro
            records = @record.send(association).to_a

            unless records.nil?
              association_options = include_has_options ? include_associations[association] : base_only_or_except
              opts = options.merge(association_options)
              yield(association, records, opts, association_type)
            end
          end
          options[:include] = include_associations
        end
      end

      def serializable_record
        returning(serializable_record = {}) do
          serializable_names.each { |name| serializable_record[name] = @record.send(name) }
          add_includes do |association, records, opts, association_type|
            if [:has_one, :belongs_to].include?(association_type)
              serializable_record[association] = records.collect { |r| self.class.new(r, opts).serializable_record }.first
            else
              serializable_record[association] = records.collect { |r| self.class.new(r, opts).serializable_record }
            end
          end
        end
      end
    end
  end
end