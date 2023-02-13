# frozen_string_literal: true
module Bulkrax
  module StatusInfo
    extend ActiveSupport::Concern

    included do
      has_many :statuses, as: :statusable, dependent: :destroy
      has_one :latest_status,
              -> { merge(Status.latest_by_statusable) },
              as: :statusable,
              class_name: "Bulkrax::Status",
              inverse_of: :statusable
    end

    def current_status
      last_status = self.statuses.last
      last_status if last_status && last_status.runnable == last_run
    end

    def failed?
      current_status&.status_message&.eql?('Failed')
    end

    def succeeded?
      current_status&.status_message&.match(/^Complete$/)
    end

    def status
      current_status&.status_message || 'Pending'
    end

    def status_at
      current_status&.created_at
    end

    def set_status_info(e = nil, current_run = nil)
      runnable = current_run || last_run
      if e.nil?
        self.statuses.create!(status_message: 'Complete', runnable: runnable)
      elsif e.is_a?(String)
        self.statuses.create!(status_message: e, runnable: runnable)
      else
        self.statuses.create!(status_message: 'Failed', runnable: runnable, error_class: e.class.to_s, error_message: e.message, error_backtrace: e.backtrace)
      end
    end

    alias status_info set_status_info

    deprecation_deprecate status_info: "Favor Bulkrax::StatusInfo.set_status_info.  We will be removing .status_info in Bulkrax v6.0.0"

    # api compatible with previous error structure
    def last_error
      return unless current_status && current_status.error_class.present?
      {
        error_class: current_status.error_class,
        error_message: current_status.error_message,
        error_trace: current_status.error_backtrace
      }.with_indifferent_access
    end
  end
end
