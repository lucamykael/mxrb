# frozen_string_literal: true

require "fileutils"

module Mxrb
  module Semantic
    # Wraps multiple plans into a single atomic operation with rollback on failure.
    #
    # Before applying, a backup of the MPR is taken using SQLite's VACUUM INTO.
    # If any plan raises, the backup is restored and the project state is reset
    # as if the batch never ran.
    #
    # Usage:
    #   plan1 = project.plan_rename("M.OldName", to: "M.NewName")
    #   plan2 = project.plan_add_attribute("M.NewName", name: :Slug, type: :string)
    #   project.batch_plan([plan1, plan2]).apply!
    class BatchPlan
      attr_reader :plans, :changes

      def initialize(project:, plans:)
        @project = project
        @plans   = plans.freeze
        @applied = false
        @changes = @plans.flat_map { |p| p.respond_to?(:changes) ? Array(p.changes) : [] }.freeze
      end

      def empty?   = @plans.empty?
      def applied? = @applied

      def apply!
        raise ArgumentError, "batch plan was already applied" if @applied
        return self if @plans.empty?

        backup_path = "#{@project.mpr.path}.mxrb_batch_backup"
        @project.mpr.backup!(backup_path)

        begin
          @plans.each(&:apply!)
          @applied = true
        rescue => error
          @project.mpr.restore_from!(backup_path)
          @project.refresh!
          idx = @plans.index { !_1.applied? }.to_i + 1
          raise BatchError, "batch failed at plan #{idx} of #{@plans.size}: #{error.message}"
        ensure
          FileUtils.rm_f(backup_path) rescue nil # :nocov:
        end
        self
      end
    end
  end
end
