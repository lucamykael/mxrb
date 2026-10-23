# frozen_string_literal: true

# rubocop:disable Metrics

module Mxrb
  module Studio
    # Line-based three-way merge. Unlike diff3 and `git merge-file`, a change
    # on one side and an insertion on the other next to it (a commented line
    # and a new attribute below it) are not a conflict: only edits of the same
    # base lines, or two different insertions at the same place, are.
    module TextMerge
      # Beyond this many differing lines the files are treated as rewritten.
      MAXIMUM_EDITS = 1000
      Hunk = Struct.new(:side, :start, :stop, :lines)

      module_function

      # Returns [merged text, number of conflicts]. `favor` (:ours or
      # :theirs) settles conflicts instead of writing conflict markers.
      def merge(base, ours, theirs, favor: nil, labels: %w[ruby base mendix])
        original = base.lines
        groups = group(hunks(original, ours.lines, :ours) + hunks(original, theirs.lines, :theirs))
        output = []
        position = 0
        conflicts = 0
        groups.each do |hunks|
          start = hunks.map(&:start).min
          stop = hunks.map(&:stop).max
          output.concat(original[position...start])
          text, conflict = resolve(original, hunks, start, stop, favor, labels)
          conflicts += 1 if conflict
          output.concat(text)
          position = stop
        end
        output.concat(original[position..] || [])
        [output.join, conflicts]
      end

      def resolve(original, hunks, start, stop, favor, labels)
        mine = side(original, hunks, :ours, start, stop)
        incoming = side(original, hunks, :theirs, start, stop)
        return [mine || incoming, false] if mine.nil? || incoming.nil? || mine == incoming
        return [favor == :ours ? mine : incoming, true] if favor

        [markers(mine, original[start...stop], incoming, labels), true]
      end

      # The span start...stop of the base as one side changed it, or nil.
      def side(original, hunks, name, start, stop)
        own = hunks.select { _1.side == name }
        return if own.empty?

        lines = []
        position = start
        own.sort_by { [_1.start, _1.stop] }.each do |hunk|
          lines.concat(original[position...hunk.start])
          lines.concat(hunk.lines)
          position = hunk.stop
        end
        lines.concat(original[position...stop])
      end

      def markers(mine, base, incoming, labels)
        [["<<<<<<< #{labels[0]}\n"], terminated(mine), ["||||||| #{labels[1]}\n"], terminated(base),
         ["=======\n"], terminated(incoming), [">>>>>>> #{labels[2]}\n"]].flatten
      end

      def terminated(lines)
        return lines if lines.empty? || lines.last.end_with?("\n")

        lines[0...-1] + ["#{lines.last}\n"]
      end

      # Hunks that touch each other, transitively, form one group.
      def group(hunks)
        hunks.sort_by { [_1.start, _1.stop] }.each_with_object([]) do |hunk, groups|
          if groups.any? && groups.last.any? { overlap?(_1, hunk) }
            groups.last << hunk
          else
            groups << [hunk]
          end
        end
      end

      def overlap?(left, right)
        return false if left.side == right.side && !(left.start < right.stop && right.start < left.stop)

        if left.start == left.stop || right.start == right.stop
          insertion, other = left.start == left.stop ? [left, right] : [right, left]
          return insertion.start == other.start if other.start == other.stop

          other.start < insertion.start && insertion.start < other.stop
        else
          left.start < right.stop && right.start < left.stop
        end
      end

      def hunks(before, after, name)
        pairs = matches(before, after)
        result = []
        old_position = 0
        new_position = 0
        (pairs + [[before.size, after.size]]).each do |old_index, new_index|
          if old_index > old_position || new_index > new_position
            result << Hunk.new(name, old_position, old_index, after[new_position...new_index])
          end
          old_position = old_index + 1
          new_position = new_index + 1
        end
        result
      end

      # Matching line pairs of a shortest edit script (Myers), or none when
      # the files differ in more than MAXIMUM_EDITS lines.
      def matches(before, after)
        prefix = 0
        prefix += 1 while prefix < before.size && prefix < after.size && before[prefix] == after[prefix]
        suffix = 0
        while suffix < before.size - prefix && suffix < after.size - prefix &&
              before[-1 - suffix] == after[-1 - suffix]
          suffix += 1
        end
        left = before[prefix...(before.size - suffix)]
        right = after[prefix...(after.size - suffix)]
        middle = myers(left, right).map { |a, b| [a + prefix, b + prefix] }
        (0...prefix).map { [_1, _1] } + middle +
          (0...suffix).map { [before.size - suffix + _1, after.size - suffix + _1] }
      end

      def myers(left, right)
        n = left.size
        m = right.size
        return [] if n.zero? || m.zero?

        maximum = [n + m, MAXIMUM_EDITS].min
        frontier = { 1 => 0 }
        trace = []
        found = (0..maximum).find do |d|
          trace << frontier.dup
          (-d..d).step(2).any? do |k|
            down = k == -d || (k != d && frontier.fetch(k - 1, -1) < frontier.fetch(k + 1, -1))
            x = down ? frontier.fetch(k + 1, 0) : frontier.fetch(k - 1, 0) + 1
            y = x - k
            while x < n && y < m && left[x] == right[y]
              x += 1
              y += 1
            end
            frontier[k] = x
            x >= n && y >= m
          end
        end
        return [] unless found

        backtrack(trace, left, right, found)
      end

      def backtrack(trace, left, right, depth)
        x = left.size
        y = right.size
        pairs = []
        depth.downto(1) do |d|
          frontier = trace[d]
          k = x - y
          previous = k == -d || (k != d && frontier.fetch(k - 1, -1) < frontier.fetch(k + 1, -1)) ? k + 1 : k - 1
          start_x = frontier.fetch(previous, 0)
          start_y = start_x - previous
          while x > start_x && y > start_y
            x -= 1
            y -= 1
            pairs << [x, y]
          end
          x = start_x
          y = start_y
        end
        while x.positive? && y.positive?
          x -= 1
          y -= 1
          pairs << [x, y]
        end
        pairs.reverse
      end
    end
  end
end
# rubocop:enable Metrics
