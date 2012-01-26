module ActiveRecord
  class SchemaDumper
    def tables(stream)
      @connection.tables_without_views.sort.each do |tbl|
        next if ['schema_migrations', ignore_tables].flatten.any? do |ignored|
          case ignored
          when String; tbl == ignored
          when Regexp; tbl =~ ignored
          else
            raise StandardError, 'ActiveRecord::SchemaDumper.ignore_tables accepts an array of String and / or Regexp values.'
          end
        end 
        table(tbl, stream)
      end
    end
  end
end