module Molinillo
  class Resolver
    # A specific resolution from a given {Resolver}
    class Resolution
      # A conflict that the resolution process encountered
      # @attr [Object] requirement the requirement that immediately led to the conflict
      # @attr [{String,Nil=>[Object]}] requirements the requirements that caused the conflict
      # @attr [Object, nil] existing the existing spec that was in conflict with
      #   the {#possibility}
      # @attr [Object] possibility the spec that was unable to be activated due
      #   to a conflict
      # @attr [Object] locked_requirement the relevant locking requirement.
      # @attr [Array<Array<Object>>] requirement_trees the different requirement
      #   trees that led to every requirement for the conflicting name.
      Conflict = Struct.new(
        :requirement,
        :requirements,
        :existing,
        :possibility,
        :locked_requirement,
        :requirement_trees,
      )

      # @return [SpecificationProvider] the provider that knows about
      #   dependencies, requirements, specifications, versions, etc.
      attr_reader :specification_provider

      # @return [UI] the UI that knows how to communicate feedback about the
      #   resolution process back to the user
      attr_reader :resolver_ui

      # @return [DependencyGraph] the base dependency graph to which
      #   dependencies should be 'locked'
      attr_reader :base

      # @return [Array] the dependencies that were explicitly required
      attr_reader :original_requested

      # @param [SpecificationProvider] specification_provider
      #   see {#specification_provider}
      # @param [UI] resolver_ui see {#resolver_ui}
      # @param [Array] requested see {#original_requested}
      # @param [DependencyGraph] base see {#base}
      def initialize(specification_provider, resolver_ui, requested, base)
        @specification_provider = specification_provider
        @resolver_ui = resolver_ui
        @original_requested = requested
        @base = base
        @states = []
        @iteration_counter = 0
        @all_conflicts = []
      end

      # Resolves the {#original_requested} dependencies into a full dependency
      #   graph
      # @raise [ResolverError] if successful resolution is impossible
      # @return [DependencyGraph] the dependency graph of successfully resolved
      #   dependencies
      def resolve
        start_resolution

        while state
          break unless state.requirements.any? || state.requirement
          indicate_progress
          if state.respond_to?(:pop_possibility_state) # DependencyState
            debug(depth) { "Creating possibility state for #{requirement} (#{possibilities.count} remaining)" }
            state.pop_possibility_state.tap { |s| states.push(s) if s }
          end
          process_topmost_state
        end

        double_check_conflict_existing_specs

        activated.freeze
      ensure
        end_resolution
      end

      private

      # Sets up the resolution process
      # @return [void]
      def start_resolution
        @started_at = Time.now

        states.push(initial_state)

        debug { "Starting resolution (#{@started_at})" }
        resolver_ui.before_resolution
      end

      # Ends the resolution process
      # @return [void]
      def end_resolution
        resolver_ui.after_resolution
        debug do
          "Finished resolution (#{@iteration_counter} steps) " \
          "(Took #{(ended_at = Time.now) - @started_at} seconds) (#{ended_at})"
        end
        debug { 'Unactivated: ' + Hash[activated.vertices.reject { |_n, v| v.payload }].keys.join(', ') } if state
        debug { 'Activated: ' + Hash[activated.vertices.select { |_n, v| v.payload }].keys.join(', ') } if state
      end

      require 'molinillo/state'
      require 'molinillo/modules/specification_provider'

      # @return [Integer] the number of resolver iterations in between calls to
      #   {#resolver_ui}'s {UI#indicate_progress} method
      attr_accessor :iteration_rate

      # @return [Time] the time at which resolution began
      attr_accessor :started_at

      # @return [Array<ResolutionState>] the stack of states for the resolution
      attr_accessor :states

      # @return [Array<Array(String,Object)>] an array of duples of name and
      #   existing spec for all conflicts.
      attr_accessor :all_conflicts

      ResolutionState.new.members.each do |member|
        define_method member do |*args, &block|
          state.send(member, *args, &block)
        end
      end

      SpecificationProvider.instance_methods(false).each do |instance_method|
        define_method instance_method do |*args, &block|
          begin
            specification_provider.send(instance_method, *args, &block)
          rescue NoSuchDependencyError => error
            if state
              vertex = activated.vertex_named(name_for error.dependency)
              error.required_by += vertex.incoming_edges.map { |e| e.origin.name }
              error.required_by << name_for_explicit_dependency_source unless vertex.explicit_requirements.empty?
            end
            raise
          end
        end
      end

      # Processes the topmost available {RequirementState} on the stack
      # @return [void]
      def process_topmost_state
        if possibility
          attempt_to_activate
        else
          create_conflict if state.is_a? PossibilityState
          unwind_for_conflict until possibility && state.is_a?(DependencyState)
        end
      end

      # @return [Object] the current possibility that the resolution is trying
      #   to activate
      def possibility
        possibilities.last
      end

      # @return [RequirementState] the current state the resolution is
      #   operating upon
      def state
        states.last
      end

      # Creates the initial state for the resolution, based upon the
      # {#requested} dependencies
      # @return [DependencyState] the initial state for the resolution
      def initial_state
        graph = DependencyGraph.new.tap do |dg|
          original_requested.each { |r| dg.add_root_vertex(name_for(r), nil).tap { |v| v.explicit_requirements << r } }
        end

        requirements = sort_dependencies(original_requested, graph, {})
        initial_requirement = requirements.shift
        DependencyState.new(
          initial_requirement && name_for(initial_requirement),
          requirements,
          graph,
          initial_requirement,
          initial_requirement && search_for(initial_requirement),
          0,
          {}
        )
      end

      # Unwinds the states stack because a conflict has been encountered
      # @return [void]
      def unwind_for_conflict
        debug(depth) { "Unwinding for conflict: #{requirement}" }
        conflicts.tap do |c|
          states.slice!((state_index_for_unwind + 1)..-1)
          raise VersionConflict.new(c) unless state
          state.conflicts = c
        end
      end

      # @return [Integer] The index to which the resolution should unwind in the
      #   case of conflict.
      def state_index_for_unwind
        current_requirement = requirement
        existing_requirement = requirement_for_existing_name(name)
        until current_requirement.nil? && existing_requirement.nil?
          current_state = find_state_for(current_requirement)
          existing_state = find_state_for(existing_requirement)
          return states.index(current_state) if state_any?(current_state)
          return states.index(existing_state) if state_any?(existing_state)
          existing_requirement = parent_of(existing_requirement)
          current_requirement = parent_of(current_requirement)
        end
        -1
      end

      # @return [Object] the requirement that led to `requirement` being added
      #   to the list of requirements.
      def parent_of(requirement)
        return nil unless requirement
        seen = false
        state = states.reverse_each.find do |s|
          seen ||= s.requirement == requirement
          seen && s.requirement != requirement && !s.requirements.include?(requirement)
        end
        state && state.requirement
      end

      # @return [Object] the requirement that led to a version of a possibility
      #   with the given name being activated.
      def requirement_for_existing_name(name)
        return nil unless activated.vertex_named(name).payload
        states.reverse_each.find { |s| !s.activated.vertex_named(name).payload }.requirement
      end

      # @return [ResolutionState] the state whose `requirement` is the given
      #   `requirement`.
      def find_state_for(requirement)
        return nil unless requirement
        states.find { |i| requirement == i.requirement }
      end

      # @return [Boolean] whether or not the given state has any possibilities
      #   left.
      def state_any?(state)
        state && state.possibilities.any?
      end

      # Enumerate over {#all_conflicts} and ensure that already activated specs
      # that were backtracked from were not that optimal possibilities that
      # should have been activated instead, and swaps them in if such a simple
      # switch is possible.
      # @return [void]
      def double_check_conflict_existing_specs
        debug { "Double checking conflicts' existing specs" }
        all_conflicts.each do |name, conflict_possibility|
          next unless conflict_possibility
          vertex = activated.vertex_named(name)
          possibilities = search_for(vertex.requirements.first)
          conflict_index = possibilities.index(conflict_possibility)
          payload_index = possibilities.index(vertex.payload)
          if conflict_index && payload_index && conflict_index > payload_index
            if safe_to_swap?(name, conflict_possibility)
              debug { "Swapping #{conflict_possibility} in for #{activated.vertex_named(name).payload}" }
              vertex.payload = conflict_possibility
            end
          end
        end
      end

      # @param  [String] name
      # @param  [Object] conflict_possibility the existing possibility from a
      #   conflict that is being attempted to be swapped for the current
      #   activated spec of the given name.
      # @return [Boolen] whether it is safe to swap in `conflict possibility`.
      def safe_to_swap?(name, conflict_possibility)
        duplicate_activated = activated.dup
        duplicate_activated.vertex_named(name).payload = conflict_possibility
        locked_requirement = locked_requirement_named(name)
        (!locked_requirement || requirement_satisfied_by?(locked_requirement, a, conflict_possibility)) &&
          activated.vertex_named(name).requirements.all? do |r|
            requirement_satisfied_by?(r, duplicate_activated, conflict_possibility)
          end &&
          dependencies_for(conflict_possibility).all? { |r| existing_spec_satisfied_by?(r, duplicate_activated) }
      end

      # @param  [Object] requirement the requirement.
      # @param  [DependencyGraph] duplicate_activated the dependency graph that
      #   should be used when checking for satisfaction.
      # @return [Boolean] whether the existing spec satisfies the given
      #   requirement.
      def existing_spec_satisfied_by?(requirement, duplicate_activated)
        name = name_for(requirement)
        activated.vertex_named(name) && payload = activated.vertex_named(name).payload
        payload && requirement_satisfied_by(requirement, duplicate_activated, payload)
      end

      # @return [Conflict] a {Conflict} that reflects the failure to activate
      #   the {#possibility} in conjunction with the current {#state}
      def create_conflict
        vertex = activated.vertex_named(name)
        existing = vertex.payload
        requirements = {
          name_for_explicit_dependency_source => vertex.explicit_requirements,
          name_for_locking_dependency_source => Array(locked_requirement_named(name)),
        }
        vertex.incoming_edges.each { |edge| (requirements[edge.origin.payload] ||= []).unshift(*edge.requirements) }
        all_conflicts << [name, existing]
        conflicts[name] = Conflict.new(
          requirement,
          Hash[requirements.select { |_, r| !r.empty? }],
          existing,
          possibility,
          locked_requirement_named(name),
          requirement_trees,
        )
      end

      # @return [Array<Array<Object>>] rhe different requirement
      #   trees that led to every requirement for the current spec.
      def requirement_trees
        activated.vertex_named(name).requirements.map { |r| requirement_tree_for(r) }
      end

      # @return [Array<Object>] the list of requirements that led to
      #   `requirement` being required.
      def requirement_tree_for(requirement)
        tree = []
        while requirement
          tree.unshift(requirement)
          requirement = parent_of(requirement)
        end
        tree
      end

      # Indicates progress roughly once every second
      # @return [void]
      def indicate_progress
        @iteration_counter += 1
        @progress_rate ||= resolver_ui.progress_rate
        if iteration_rate.nil?
          if Time.now - started_at >= @progress_rate
            self.iteration_rate = @iteration_counter
          end
        end

        if iteration_rate && (@iteration_counter % iteration_rate) == 0
          resolver_ui.indicate_progress
        end
      end

      # Calls the {#resolver_ui}'s {UI#debug} method
      # @param [Integer] depth the depth of the {#states} stack
      # @param [Proc] block a block that yields a {#to_s}
      # @return [void]
      def debug(depth = 0, &block)
        resolver_ui.debug(depth, &block)
      end

      # Attempts to activate the current {#possibility}
      # @return [void]
      def attempt_to_activate
        debug(depth) { 'Attempting to activate ' + possibility.to_s }
        existing_node = activated.vertex_named(name)
        if existing_node.payload
          debug(depth) { "Found existing spec (#{existing_node.payload})" }
          attempt_to_activate_existing_spec(existing_node)
        else
          attempt_to_activate_new_spec
        end
      end

      # Attempts to activate the current {#possibility} (given that it has
      # already been activated)
      # @return [void]
      def attempt_to_activate_existing_spec(existing_node)
        existing_spec = existing_node.payload
        if requirement_satisfied_by?(requirement, activated, existing_spec)
          new_requirements = requirements.dup
          push_state_for_requirements(new_requirements)
        else
          create_conflict
          debug(depth) { "Unsatisfied by existing spec (#{existing_node.payload})" }
          unwind_for_conflict
        end
      end

      # Attempts to activate the current {#possibility} (given that it hasn't
      # already been activated)
      # @return [void]
      def attempt_to_activate_new_spec
        satisfied = begin
          locked_requirement = locked_requirement_named(name)
          requested_spec_satisfied = requirement_satisfied_by?(requirement, activated, possibility)
          locked_spec_satisfied = !locked_requirement ||
            requirement_satisfied_by?(locked_requirement, activated, possibility)
          debug(depth) { 'Unsatisfied by requested spec' } unless requested_spec_satisfied
          debug(depth) { 'Unsatisfied by locked spec' } unless locked_spec_satisfied
          requested_spec_satisfied && locked_spec_satisfied
        end
        if satisfied
          activate_spec
        else
          create_conflict
          unwind_for_conflict
        end
      end

      # @param [String] requirement_name the spec name to search for
      # @return [Object] the locked spec named `requirement_name`, if one
      #   is found on {#base}
      def locked_requirement_named(requirement_name)
        vertex = base.vertex_named(requirement_name)
        vertex && vertex.payload
      end

      # Add the current {#possibility} to the dependency graph of the current
      # {#state}
      # @return [void]
      def activate_spec
        conflicts.delete(name)
        debug(depth) { 'Activated ' + name + ' at ' + possibility.to_s }
        vertex = activated.vertex_named(name)
        vertex.payload = possibility
        require_nested_dependencies_for(possibility)
      end

      # Requires the dependencies that the recently activated spec has
      # @param [Object] activated_spec the specification that has just been
      #   activated
      # @return [void]
      def require_nested_dependencies_for(activated_spec)
        nested_dependencies = dependencies_for(activated_spec)
        debug(depth) { "Requiring nested dependencies (#{nested_dependencies.map(&:to_s).join(', ')})" }
        nested_dependencies.each { |d|  activated.add_child_vertex name_for(d), nil, [name_for(activated_spec)], d }

        push_state_for_requirements(requirements + nested_dependencies)
      end

      # Pushes a new {DependencyState} that encapsulates both existing and new
      # requirements
      # @param [Array] new_requirements
      # @return [void]
      def push_state_for_requirements(new_requirements)
        new_requirements = sort_dependencies(new_requirements, activated, conflicts)
        new_requirement = new_requirements.shift
        states.push DependencyState.new(
          new_requirement ? name_for(new_requirement) : '',
          new_requirements,
          activated.dup,
          new_requirement,
          new_requirement ? search_for(new_requirement) : [],
          depth,
          conflicts.dup
        )
      end
    end
  end
end
