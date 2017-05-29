# encoding: UTF-8
#
# Copyright (c) 2010-2017 GoodData Corporation. All rights reserved.
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

require 'terminal-table'

require_relative 'actions/actions'
require_relative 'dsl/dsl'
require_relative 'helpers/helpers'

module GoodData
  module LCM2
    class SmartHash < Hash
      def method_missing(name, *_args)
        key = name.to_s.downcase.to_sym

        value = nil
        keys.each do |k|
          if k.to_s.downcase.to_sym == key
            value = self[k]
            break
          end
        end

        if value
          value
        else
          begin
            super
          rescue
            nil
          end
        end
      end

      def key?(key)
        return true if super

        keys.each do |k|
          return true if k.to_s.downcase.to_sym == key.to_s.downcase.to_sym
        end

        false
      end

      def respond_to_missing?(name, *_args)
        key = name.to_s.downcase.to_sym
        key?(key)
      end
    end

    MODES = {
      # Low Level Commands

      actions: [
        PrintActions
      ],

      hello: [
        HelloWorld
      ],

      modes: [
        PrintModes
      ],

      info: [
        PrintTypes,
        PrintActions,
        PrintModes
      ],

      types: [
        PrintTypes
      ],

      ## Bricks

      release: [
        EnsureReleaseTable,
        SegmentsFilter,
        CreateSegmentMasters,
        EnsureTechnicalUsersDomain,
        EnsureTechnicalUsersProject,
        SynchronizeLdm,
        CollectMeta,
        CollectTaggedObjects,
        CollectComputedAttributeMetrics,
        ImportObjectCollections,
        SynchronizeComputedAttributes,
        SynchronizeLabelTypes,
        SynchronizeAttributeDrillpath,
        SynchronizeProcesses,
        SynchronizeSchedules,
        SynchronizeColorPalette,
        SynchronizeNewSegments,
        UpdateReleaseTable
      ],

      provision: [
        EnsureReleaseTable,
        CollectSegments,
        PurgeClients,
        CollectClients,
        AssociateClients,
        ProvisionClients,
        EnsureTechnicalUsersDomain,
        EnsureTechnicalUsersProject,
        SynchronizeETLsInSegment
      ],

      rollout: [
        EnsureReleaseTable,
        CollectSegments,
        CollectSegmentClients,
        EnsureTechnicalUsersDomain,
        EnsureTechnicalUsersProject,
        SynchronizeLdm,
        CollectComputedAttributeMetrics,
        ImportObjectCollections,
        SynchronizeComputedAttributes, # need to sync CA here to maintain the drill path after that
        # SynchronizeLabelTypes,
        SynchronizeAttributeDrillpath,
        ApplyCustomMaql,
        SynchronizeColorPalette,
        SynchronizeClients,
        SynchronizeETLsInSegment
      ]
    }

    MODE_NAMES = MODES.keys

    class << self
      def convert_params(params)
        # Symbolize all keys
        GoodData::Helpers.symbolize_keys!(params)
        convert_to_smart_hash(params)
      end

      def convert_to_smart_hash(params)
        if params.is_a?(Hash)
          res = SmartHash.new
          params.each_pair do |k, v|
            if v.is_a?(Hash) || v.is_a?(Array)
              res[k] = convert_to_smart_hash(v)
            else
              res[k] = v
            end
          end
          res
        elsif params.is_a?(Array)
          params.map do |item|
            convert_to_smart_hash(item)
          end
        else
          params
        end
      end

      def get_mode_actions(mode)
        mode = mode.to_sym
        actions = MODES[mode]
        if mode == :generic_lifecycle
          []
        else
          actions || fail("Invalid mode specified '#{mode}', supported modes are: '#{MODE_NAMES.join(', ')}'")
        end
      end

      def print_action_names(mode, actions)
        title = "Actions to be performed for mode '#{mode}'"

        headings = %w(# NAME DESCRIPTION)

        rows = []
        actions.each_with_index do |action, index|
          rows << [index, action.short_name, action.const_defined?(:DESCRIPTION) && action.const_get(:DESCRIPTION)]
        end

        table = Terminal::Table.new :title => title, :headings => headings do |t|
          rows.each_with_index do |row, index|
            t << row
            t.add_separator if index < rows.length - 1
          end
        end
        puts "\n#{table}"
      end

      def print_action_result(action, messages)
        title = "Result of #{action.short_name}"

        keys = if action.const_defined?('RESULT_HEADER')
                 action.const_get('RESULT_HEADER')
               else
                 GoodData.logger.warn("Action #{action.name} does not have RESULT_HEADERS, inferring headers from results.")
                 (messages.first && messages.first.keys) || []
               end

        headings = keys.map(&:upcase)

        rows = messages && messages.map do |message|
          unless message
            GoodData.logger.warn("Found an empty message in the results of the #{action.name} action")
            next
          end
          row = []
          keys.each do |heading|
            row << message[heading]
          end
          row
        end

        rows ||= []

        table = Terminal::Table.new :title => title, :headings => headings do |t|
          rows.each_with_index do |row, index|
            t << row
            t.add_separator if index < rows.length - 1
          end
        end

        puts "\n#{table}"
      end

      def print_actions_result(actions, results)
        actions.each_with_index do |action, index|
          print_action_result(action, results[index])
          puts
        end
        nil
      end

      def perform(mode, params = {})
        params = convert_params(params)

        # Get actions for mode specified
        actions = get_mode_actions(mode)
        if params.actions
          actions = params.actions.map do |action|
            "GoodData::LCM2::#{action}".split('::').inject(Object) do |o, c|
              begin
                o.const_get(c)
              rescue NameError
                fail NameError, "Cannot find action 'GoodData::LCM2::#{action}'"
              end
            end
          end
        end

        check_unused_params(actions, params)

        # Print name of actions to be performed for debug purposes
        print_action_names(mode, actions)

        # TODO: Check all action params first

        new_params = params

        fail_early = if params.key?(:fail_early)
                       params.fail_early.to_b
                     else
                       true
                     end

        strict_mode = if params.key?(:strict)
                        params.strict.to_b
                      else
                        true
                      end

        # Run actions
        errors = []
        results = []
        actions.each do |action|
          puts

          # Invoke action
          begin
            # Check if all required parameters were passed
            BaseAction.check_params(action.const_get('PARAMS'), params)

            out = action.send(:call, params)
          rescue => e
            errors << {
              action: action,
              err: e,
              backtrace: e.backtrace
            }
            break if fail_early
          end

          # Handle output results and params
          res = out.is_a?(Array) ? out : out[:results]
          out_params = out.is_a?(Hash) ? out[:params] || {} : {}
          new_params = convert_to_smart_hash(out_params)

          # Merge with new params
          params.merge!(new_params)

          # Print action result
          puts
          print_action_result(action, res)

          # Store result for final summary
          results << res
        end

        # Fail whole execution if there is any failed action
        fail(JSON.pretty_generate(errors)) if strict_mode && errors.any?

        if actions.length > 1
          puts
          puts 'SUMMARY'
          puts

          # Print execution summary/results
          print_actions_result(actions, results)
        end

        brick_results = {}
        actions.each_with_index do |action, index|
          brick_results[action.short_name] = results[index]
        end

        {
          actions: actions.map(&:short_name),
          results: brick_results,
          params: params
        }
      end

      def check_unused_params(actions, params)
        default_params = [
          :client_gdc_hostname,
          :client_gdc_protocol,
          :fail_early,
          :gdc_logger,
          :gdc_password,
          :gdc_username,
          :strict
        ]

        action_params = actions.map do |action|
          action.const_get(:PARAMS).keys.map(&:downcase)
        end

        action_params.flatten!.uniq!

        param_names = params.keys.map(&:downcase)

        unused_params = param_names - (action_params + default_params)

        if unused_params.any?
          GoodData.logger.warn("Following params are not used by any action: #{JSON.pretty_generate(unused_params)}")

          rows = []
          actions.each do |action|
            action_params = action.const_get(:PARAMS)
            action_params.each do |_k, v|
              rows << [action.short_name, v[:name], v[:description], v[:type].class.short_name]
            end
          end

          table = Terminal::Table.new :headings => ['Action', 'Parameter', 'Description', 'Parameter Type'], :rows => rows
          puts table.to_s
        end
      end
    end
  end
end
