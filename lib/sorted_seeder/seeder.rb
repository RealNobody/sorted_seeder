module SortedSeeder
  class Seeder
    attr_reader :table
    attr_reader :seeder_class

    @@create_order        = nil
    @@seeder_classes      = nil
    @@database_connection = nil

    class SeederSorter
      attr_accessor :seed_base_object

      def initialize(seed_base_object)
        @seed_base_object = seed_base_object
      end

      def <=>(other_object)
        compare_value = nil
        compare_value = (@seed_base_object <=> other_object.seed_base_object) if @seed_base_object.respond_to?(:<=>)

        unless compare_value
          compare_value = (other_object.seed_base_object <=> @seed_base_object) if other_object.seed_base_object.respond_to?(:<=>)

          if compare_value
            compare_value = -1 * compare_value
          else
            if other_object.seed_base_object.is_a?(Class)
              if seed_base_object.is_a?(Class)
                compare_value = (seed_base_object.name <=> other_object.seed_base_object.name)
              else
                compare_value = -1
              end
            else
              if seed_base_object.is_a?(Class)
                compare_value = 1
              else
                compare_value = 0
              end
            end
          end
        end

        compare_value
      end
    end

    class << self
      def seed_all(db_connection = nil)
        seeder_classes(db_connection).each do |seed_class|
          seed_class.seed
        end
      end

      def seeder_classes(db_connection = nil)
        unless @@seeder_classes
          @@seeder_classes = []

          # table object seeders
          SortedSeeder::Seeder.create_order(db_connection).each do |table|
            table_seed_class = SortedSeeder::Seeder.seed_class(table.name)

            if !table_seed_class && table.respond_to?(:seed)
              table_seed_class = table
            end

            @@seeder_classes << SortedSeeder::Seeder.new(table, table_seed_class)
          end

          # table object seeders
          SortedSeeder::Seeder.unclassed_tables(db_connection).each do |table|
            table_seed_class = SortedSeeder::Seeder.seed_class(table)

            @@seeder_classes << SortedSeeder::Seeder.new(table, table_seed_class)
          end

          if Object.const_defined?("Rails", false)
            seeder_root  = Rails.root.join("db/seeders/").to_s
            seeder_files = Dir[Rails.root.join("db/seeders/**/*.rb")]

            seeder_files.each do |seeder_file|
              class_name = File.basename(seeder_file, ".rb").classify

              check_class, full_module_name = find_file_class(seeder_file, seeder_root)
              unless check_class && check_class.const_defined?(class_name, false)
                require seeder_file
                check_class, full_module_name = find_file_class(seeder_file, seeder_root)
              end

              if check_class
                full_module_name << class_name
                if check_class.const_defined?(class_name, false)
                  check_class = full_module_name.join("::").constantize
                else
                  check_class = nil
                end
              end

              if check_class && check_class.respond_to?(:seed)
                unless @@seeder_classes.include?(check_class) ||
                    @@seeder_classes.any? { |seeder| seeder.is_a?(SortedSeeder::Seeder) && seeder.seeder_class == check_class }
                  @@seeder_classes << check_class
                end
              end
            end
          end

          seed_sorts = @@seeder_classes.map { |seed_class| SeederSorter.new(seed_class) }
          seed_sorts.sort!

          @@seeder_classes = seed_sorts.map(&:seed_base_object)
        end

        @@seeder_classes
      end

      def find_file_class(seeder_file, seeder_root)
        check_class      = Object
        full_module_name = []

        File.dirname(seeder_file.to_s[seeder_root.length..-1]).split("/").map do |module_element|
          if (module_element != ".")
            full_module_name << module_element.classify
            if check_class.const_defined?(full_module_name[-1], false)
              check_class = full_module_name.join("::").constantize
            else
              check_class = nil
              break
            end
          end
        end

        return check_class, full_module_name
      end

      def unclassed_tables(db_connection = nil)
        create_order(db_connection)

        @@other_tables
      end

      def create_order(db_connection = nil)
        unless @@create_order
          @@database_connection = db_connection

          if Object.const_defined?("ActiveRecord", false) && ActiveRecord.const_defined?("Base", false)
            @@database_connection ||= ActiveRecord::Base
          end

          if Object.const_defined?("Sequel", false) && Sequel.const_defined?("Model", false)
            @@database_connection ||= Sequel::DATABASES[0]
          end

          @@create_order = []
          @@other_tables = []

          if Object.const_defined?("ActiveRecord", false) && ActiveRecord.const_defined?("Base", false)
            active_record_create_order
          end

          if Object.const_defined?("Sequel", false) && Sequel.const_defined?("Model", false)
            sequel_record_create_order
          end
        end

        @@create_order
      end

      def active_record_create_order
        table_objects      = []
        polymorphic_tables = {}

        @@database_connection.connection rescue nil
        if @@database_connection.respond_to?(:connected?) && @@database_connection.connected?
          @@database_connection.connection.tables.each do |table_name|
            table = nil

            seeder = SortedSeeder::Seeder.seed_class(table_name, true)
            if seeder && seeder.respond_to?(:table)
              table = seeder.table
            end
            if !table && Object.const_defined?(table_name.to_s.classify)
              table = table_name.to_s.classify.constantize
            end

            # is_a?(ActiveRecord::Base) doesn't work, so I am doing it this way...
            table_is_active_record = false
            table_super_class      = table.superclass if table
            while !table_is_active_record && table_super_class
              table_is_active_record = (table_super_class == ActiveRecord::Base)
              table_super_class      = table_super_class.superclass
            end

            if table && table_is_active_record
              table_objects << table
            else
              SortedSeeder::Seeder.unclassed_tables << table_name
            end
          end

          table_objects.each do |table|
            [:has_one, :has_many].each do |relationship|
              table.reflect_on_all_associations(relationship).each do |association|
                if association.options[:as]
                  polymorphic_tables[association.class_name] ||= []

                  unless polymorphic_tables[association.class_name].include?(table)
                    polymorphic_tables[association.class_name] << table
                  end
                end
              end
            end
          end

          table_objects.each do |table|
            unless SortedSeeder::Seeder.create_order.include?(table)
              prev_table = active_record_pre_table(table, polymorphic_tables, [])

              while (prev_table)
                SortedSeeder::Seeder.create_order << prev_table
                prev_table = active_record_pre_table(table, polymorphic_tables, [])
              end

              SortedSeeder::Seeder.create_order << table
            end
          end
        end
      end

      def sequel_record_create_order
        if Sequel::DATABASES.length > 0
          table_objects      = []
          polymorphic_tables = {}

          raise("Unsure what database to use.") if Sequel::DATABASES.length > 1
          @@database_connection.tables.each do |table_name|
            table = nil

            seeder = SortedSeeder::Seeder.seed_class(table_name, true)
            if seeder && seeder.respond_to?(:table)
              table = seeder.table
            end
            if !table && Object.const_defined?(table_name.to_s.classify)
              table = table_name.to_s.classify.constantize
            end

            # is_a?(Sequel::Model) doesn't work, so I am doing it this way...
            table_is_sequel_model = false
            table_super_class     = table.superclass if table
            while !table_is_sequel_model && table_super_class
              table_is_sequel_model = (table_super_class == Sequel::Model)
              table_super_class     = table_super_class.superclass
            end

            if table && table_is_sequel_model
              table_objects << table
            else
              SortedSeeder::Seeder.unclassed_tables << table_name
            end
          end

          # Sequel doesn't natively support polymorphic tables, so we don't support them here.
          table_objects.each do |table|
            unless SortedSeeder::Seeder.create_order.include?(table)
              prev_table = sequel_pre_table(table, polymorphic_tables, [])

              while (prev_table)
                SortedSeeder::Seeder.create_order << prev_table
                prev_table = sequel_pre_table(table, polymorphic_tables, [])
              end

              SortedSeeder::Seeder.create_order << table
            end
          end
        end
      end

      def active_record_pre_table(table, polymorphic_tables, processing_tables)
        processing_tables << table
        prev_table = nil

        relations = table.reflect_on_all_associations(:belongs_to)
        relations.each do |belongs_to|
          if belongs_to.options && belongs_to.options[:polymorphic]
            if polymorphic_tables[table.name]
              polymorphic_tables[table.name].each do |polymorphic_prev_table|
                prev_table = polymorphic_prev_table unless SortedSeeder::Seeder.create_order.include?(polymorphic_prev_table)
                break if prev_table
              end
            end
          else
            belongs_to_table_name = (belongs_to.options[:class_name] || belongs_to.name.to_s.classify).to_s
            prev_table = belongs_to_table_name.constantize rescue nil

            # belongs_to.klass SHOULD be what I want.
            # for some reason when I was testing, this wasn't working well for me.
            # I don't remember what happened, how or why.
            # There ARE definite cases where the constantize doesn't work, so if it doesn't, fall back to the klass.
            prev_table ||= belongs_to.klass

            if prev_table &&
                (SortedSeeder::Seeder.create_order.include?(prev_table) ||
                    table == prev_table ||
                    processing_tables.include?(prev_table))
              prev_table = nil
            end
          end

          prev_prev_table = nil
          prev_prev_table = active_record_pre_table(prev_table, polymorphic_tables, processing_tables) if prev_table
          prev_table      = prev_prev_table || prev_table

          break if prev_table
        end

        prev_table
      end

      # associated_class is late-bound, and Sequel doesn't validate it until it is called.
      # This causes it to be able to fail unexpectedly, This is just a little safer...
      def sequel_associated_class(relation)
        begin
          relation.associated_class
        rescue NameError => error
          if Object.const_defined?(relation[:class_name].to_s.classify)
            relation[:class_name].to_s.classify.constantize
          else
            nil
          end
        end
      end

      def sequel_pre_table(table, polymorphic_tables, processing_tables)
        processing_tables << table
        prev_table = nil

        relations = table.all_association_reflections
        relations.each do |belongs_to|
          next unless [:one_through_one, :one_to_one, :many_to_one].include?(belongs_to[:type])

          if [:one_through_one, :one_to_one].include?(belongs_to[:type])
            related_table = sequel_associated_class(belongs_to)
            if related_table
              related_table.all_association_reflections.each do |reverse_reflection|
                if sequel_associated_class(reverse_reflection) == table
                  if [:one_to_many].include? reverse_reflection[:type]
                    prev_table = related_table
                    break
                  end
                end
              end
            end
          else
            prev_table = sequel_associated_class(belongs_to)
          end

          if prev_table &&
              (SortedSeeder::Seeder.create_order.include?(prev_table) ||
                  table == prev_table ||
                  processing_tables.include?(prev_table))
            prev_table = nil
          end

          prev_prev_table = nil
          prev_prev_table = sequel_pre_table(prev_table, polymorphic_tables, processing_tables) if prev_table
          prev_table      = prev_prev_table || prev_table

          break if prev_table
        end

        prev_table
      end

      def seed_class(table_name, seek_table_name = false)
        seed_class_name      = "#{table_name.to_s.classify}Seeder"
        seed_class_base_name = seed_class_name.demodulize
        base_module          = seed_class_name.split("::")[0..-2].join("::")
        base_module_classes  = [Object]

        unless base_module.blank?
          base_module_classes = base_module_classes.unshift base_module.constantize
        end

        return_class = nil
        2.times do
          base_module_classes.each do |base_class|
            if (base_class.const_defined?(seed_class_base_name, false))
              if base_class == Object
                return_class = seed_class_base_name.constantize
              else
                return_class = "#{base_class.name}::#{seed_class_base_name}".constantize
              end

              break
            end
          end

          break if return_class

          seeder_file = "db/seeders/"
          seeder_file += base_module.split("::").map { |module_name| module_name.underscore }.join("/")
          seeder_file += "/" unless seeder_file[-1] == "/"
          seeder_file += seed_class_base_name.underscore
          seeder_file += ".rb"
          seeder_file = File.join(Rails.root, seeder_file)

          break unless File.exists?(seeder_file)

          require seeder_file
        end

        unless return_class.respond_to?(:seed)
          unless seek_table_name && return_class.respond_to?(:table)
            return_class = nil
          end
        end

        return_class
      end
    end

    def initialize(table, seeder_class)
      @table        = table
      @seeder_class = seeder_class
    end

    def seed
      seeder_class.seed if seeder_class
    end

    def <=>(other_object)
      if (other_object.is_a?(SortedSeeder::Seeder))
        return 0 if other_object.table == self.table

        SortedSeeder::Seeder.create_order.each do |create_table|
          if create_table == self.table
            return -1
          elsif create_table == other_object.table
            return 1
          end
        end
      else
        if other_object.respond_to?(:<=>)
          comparison = (other_object <=> self)
          if comparison
            return -1 * comparison
          end
        end
      end

      return -1
    end
  end
end