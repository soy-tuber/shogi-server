## Copyright (C) 2026 soy-tuber
##
## This program is free software; you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation; either version 2 of the License, or
## (at your option) any later version.

require 'json'
require 'time'

module ShogiServer

  # Periodically writes a JSON manifest of currently active games to a file.
  # Intended to be served by nginx behind a CDN, so spectator clients can
  # discover in-progress games without connecting to the CSA server.
  #
  # The writer thread holds $mutex only long enough to copy primitive
  # attributes out of $league.games; JSON serialization and the file write
  # happen outside the lock. The file is replaced atomically via rename.
  #
  class ManifestWriter

    def initialize(file_path, interval_sec)
      @file_path = file_path
      @interval  = interval_sec > 0 ? interval_sec : 3
      @thread    = nil
      @stopped   = false
    end

    def start
      @thread = Thread.start do
        Thread.pass
        until @stopped
          begin
            write_once
          rescue Exception => ex
            log_error("ManifestWriter: #{ex.class}: #{ex.message}\n\t#{ex.backtrace.first}")
          end
          # Sleep until stopped or interval elapses. wakeup from #stop
          # interrupts this sleep.
          begin
            sleep @interval
          rescue
          end
        end
      end
    end

    def stop
      @stopped = true
      if @thread
        @thread.wakeup if @thread.alive?
        @thread.join(5)
      end
    end

    private

    def write_once
      snapshot = nil
      $mutex.synchronize do
        snapshot = $league.games.map do |id, game|
          {
            "id"         => id,
            "game_name"  => game.game_name,
            "sente"      => game.sente && game.sente.name,
            "gote"       => game.gote && game.gote.name,
            "move_count" => game.board ? game.board.move_count : 0
          }
        end
      end

      payload = {
        "generated_at" => Time.now.iso8601,
        "revision"     => ShogiServer::Revision,
        "active_games" => snapshot
      }

      tmp = "#{@file_path}.#{Process.pid}.tmp"
      File.open(tmp, "w") {|f| f.write(JSON.generate(payload)) }
      File.rename(tmp, @file_path)
    end
  end

end
