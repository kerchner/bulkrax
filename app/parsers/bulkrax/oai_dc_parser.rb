module Bulkrax
  class OaiDcParser < ApplicationParser
    attr_accessor :client, :headers
    delegate :list_sets, to: :client

    def initialize(importer)
      super
      @headers = { from: importer.user.email }
    end

    def client
      @client ||= OAI::Client.new(importer.parser_fields['base_url'],
                                  headers: headers,
                                  parser: 'libxml',
                                  metadata_prefix: importer.parser_fields['metadata_prefix'])
    end

    def collection_name
      @collection_name ||= parser_fields['set'] || 'all'
    end

    def entry_class
      OaiDcEntry
    end

    def collection_entry_class
      OaiSetEntry
    end

    def records(opts = {})
      opts.merge!(set: collection_name) unless collection_name == 'all'

      if importer.last_imported_at && only_updates
        opts.merge!(from: importer&.last_imported_at&.strftime("%Y-%m-%d"))
      end

      if opts[:quick]
        opts.delete(:quick)
        begin
          @short_records = client.list_identifiers(opts)
        rescue OAI::Exception => e
          if e.code == "noRecordsMatch"
            @short_records = []
          else
            raise e
          end
        end
      else
        begin
          @records ||= client.list_records(opts.merge(metadata_prefix: parser_fields['metadata_prefix']))
        rescue OAI::Exception => e
          if e.code == "noRecordsMatch"
            @records = []
          else
            raise e
          end
        end
      end
    end

    # the set of fields available in the import data
    def import_fields
      ['contributor', 'coverage', 'creator', 'date', 'description', 'format', 'identifier', 'language', 'publisher', 'relation', 'rights', 'source', 'subject', 'title', 'type']
    end

    def list_sets
      client.list_sets
    end

    def run
      create_collections
      create_works
    end

    def create_collections
      metadata = {
        visibility: 'open',
        collection_type_gid: Hyrax::CollectionType.find_or_create_default_collection_type.gid
      }

      list_sets.each do |set|
        next unless collection_name == 'all' || collection_name == set.spec

        metadata[:title] = [set.name]
        metadata[Bulkrax.system_identifier_field] = [set.spec]

        new_entry = collection_entry_class.where(importer: importer, identifier: set.spec, raw_metadata: metadata).first_or_create!
        ImportWorkCollectionJob.perform_later(new_entry.id, importer.current_importer_run.id)
      end
    end

    def create_works
      results = self.records(quick: true)
      if results.present?
        results.full.each_with_index do |record, index|
          if !limit.nil? && index >= limit
            break
          elsif record.deleted? # TODO record.status == "deleted"
            importer.current_importer_run.deleted_records += 1
            importer.current_importer_run.save!
          else
            seen[record.identifier] = true
            new_entry = entry_class.where(importer: self.importer, identifier: record.identifier).first_or_create!
            ImportWorkJob.perform_later(new_entry.id, importer.current_importer_run.id)
            importer.increment_counters(index)
          end
        end
      end
    end

    def total
      @total ||= records(quick: true).doc.find(".//resumptionToken").to_a.first.attributes["completeListSize"].to_i
    rescue
      @total = 0
    end

  end
end