# TODO: require 'importer/log_subscriber'
module Bulkrax
  class ObjectFactory
    extend ActiveModel::Callbacks
    define_model_callbacks :save, :create
    class_attribute :klass, :system_identifier_field
    attr_reader :attributes, :files_directory, :object, :files

    def initialize(attributes, files_dir = nil, files = [], user = nil)
      @attributes = ActiveSupport::HashWithIndifferentAccess.new(attributes)
      @files_directory = files_dir
      @files = files
      @user = user || User.batch_user
    end

    def run
      arg_hash = { id: attributes[:id], name: 'UPDATE', klass: klass }
      @object = find
      if @object
        @object.reindex_extent = Hyrax::Adapters::NestingIndexAdapter::LIMITED_REINDEX
        ActiveSupport::Notifications.instrument('import.importer', arg_hash) { update }
      else
        ActiveSupport::Notifications.instrument('import.importer', arg_hash.merge(name: 'CREATE')) { create }
      end
      yield(object) if block_given?
      object
    end

    def update
      raise "Object doesn't exist" unless object

      run_callbacks(:save) do
        work_actor.update(environment(update_attributes))
      end
      log_updated(object)
    end

    def create_attributes
      transform_attributes
    end

    def update_attributes
      transform_attributes.except(:id)
    end

    def find
      return find_by_id if attributes[:id]
      return search_by_identifier if attributes[system_identifier_field].present?
    end

    def find_by_id
      klass.find(attributes[:id]) if klass.exists?(attributes[:id])
    end

    def search_by_identifier
      query = { system_identifier_field =>
                attributes[system_identifier_field] }
      match = klass.where(query).first
      return match if match && match.send(system_identifier_field) == attributes[system_identifier_field]
    end

    # An ActiveFedora bug when there are many habtm <-> has_many associations means they won't all get saved.
    # https://github.com/projecthydra/active_fedora/issues/874
    # 2+ years later, still open!
    def create
      attrs = create_attributes
      @object = klass.new
      @object.reindex_extent = Hyrax::Adapters::NestingIndexAdapter::LIMITED_REINDEX
      run_callbacks :save do
        run_callbacks :create do
          klass == Collection ? create_collection(attrs) : work_actor.create(environment(attrs))
        end
      end
      log_created(object)
    end

    def log_created(obj)
      msg = "Created #{klass.model_name.human} #{obj.id}"
      Rails.logger.info("#{msg} (#{Array(attributes[system_identifier_field]).first})")
    end

    def log_updated(obj)
      msg = "Updated #{klass.model_name.human} #{obj.id}"
      Rails.logger.info("#{msg} (#{Array(attributes[system_identifier_field]).first})")
    end

    private

    # @param [Hash] attrs the attributes to put in the environment
    # @return [Hyrax::Actors::Environment]
    def environment(attrs)
      Hyrax::Actors::Environment.new(@object, Ability.new(@user), attrs)
    end

    def work_actor
      Hyrax::CurationConcern.actor
    end

    def create_collection(attrs)
      @object.attributes = attrs
      @object.apply_depositor_metadata(@user)

      @object.save!
    end

    # Override if we need to map the attributes from the parser in
    # a way that is compatible with how the factory needs them.
    def transform_attributes
      attributes.slice(*permitted_attributes)
                .merge(file_attributes)
    end

    # Find existing files or upload new files. This assumes a Work will have unique file titles;
    #   and that those file titles will not have changed
    # could filter by URIs instead (slower).
    # When an uploaded_file already exists we do not want to pass its id in `file_attributes`
    # otherwise it gets reuploaded by `work_actor`.
    # support multiple files; ensure attributes[:file] is an Array
    def upload_ids
      attributes[:file] = Array.wrap(attributes[:file])
      work_files_titles = object.file_sets.map { |t| t.title.to_a }.flatten if object.present? && object.file_sets.present?
      work_files_titles && (work_files_titles & attributes[:file]).present? ? [] : import_files
    end

    def file_attributes
      hash = {}
      hash[:uploaded_files] = upload_ids if files_directory.present? && attributes[:file].present?
      hash[:remote_files] = new_remote_files if new_remote_files.present?
      hash
    end

    def new_remote_files
      @new_remote_files ||= if attributes[:remote_files].present? && object.present? && object.file_sets.present?
                              attributes[:remote_files].reject do |file|
                                existing = object.file_sets.detect { |f| f.import_url && f.import_url == file[:url] }
                                existing
                              end
                            elsif attributes[:remote_files].present?
                              attributes[:remote_files]
                            end
    end

    def file_paths
      attributes[:file]&.map { |file_name| File.join(files_directory, file_name) }
    end

    def import_files
      file_paths.map { |path| import_file(path) }
    end

    def import_file(path)
      u = Hyrax::UploadedFile.new
      u.user_id = @user.id
      u.file = CarrierWave::SanitizedFile.new(path)
      u.save
      u.id
    end

    ## TO DO: handle invalid file in CSV
    ## currently the importer stops if no file corresponding to a given file_name is found

    # Regardless of what the MODS Parser gives us, these are the properties we are prepared to accept.
    def permitted_attributes
      klass.properties.keys.map(&:to_sym) + %i[id edit_users edit_groups read_groups visibility]
    end
  end
end