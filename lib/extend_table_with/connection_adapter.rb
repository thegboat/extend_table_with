#this just keeps the views out of the schema dump. need to add view creation
#logic and other db compatibility in here
module ActiveRecord
  module ConnectionAdapters
    class MysqlAdapter < AbstractAdapter
      def tables_without_views(name = nil) #:nodoc:
        tables = []
        result = execute("SHOW FULL TABLES WHERE Table_type = 'BASE TABLE'", name)
        result.each { |field| tables << field[0] }
        result.free
        tables
      end
    end
  end
end