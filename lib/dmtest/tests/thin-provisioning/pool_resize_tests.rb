require 'dmtest/log'
require 'dmtest/process'
require 'dmtest/utils'
require 'dmtest/tags'
require 'dmtest/thinp-test'
require 'timeout'

#----------------------------------------------------------------

class PoolAndDataSizeMatchTests < ThinpTestCase
  include Tags
  include Utils
  include TinyVolumeManager

  def setup
    super
    @low_water_mark = 0
    @data_block_size = 128

    @tvm = VM.new
    @tvm.add_allocation_volume(@data_dev, 0, dev_size(@data_dev))

    @size = @volume_size
    @tvm.add_volume(linear_vol('data', @size))

    wipe_device(@metadata_dev, 8)
  end

  def pool_table(size, data)
    Table.new(ThinPoolTarget.new(size, @metadata_dev, data,
                                 @data_block_size, @low_water_mark))
  end

  #--------------------------------

  tag :thinp_target

  def test_data_cannot_be_smaller_than_pool_on_initial_load
    with_dev(@tvm.table('data')) do |data|
      table = pool_table(@size * 2, data)

      begin
        with_dev(table) {}
      rescue
        failed = true
      end

      failed.should be_true
    end
  end

  def test_data_cannot_be_smaller_than_pool_on_reload
    with_dev(@tvm.table('data')) do |data|
      table = pool_table(@size, data)
      table2 = pool_table(@size * 2, data)

      with_dev(table) do |pool|
        failed = false

        begin
          pool.pause do
            pool.load(table2)
          end
        rescue
          failed = true
        end

        failed.should be_true
        status = PoolStatus.new(pool)
        status.total_data_blocks.should == @size / @data_block_size
      end
    end
  end

  def test_extra_data_space_must_not_be_used_on_initial_load
    with_dev(@tvm.table('data')) do |data|
      table = pool_table(@size / 2, data)

      with_dev(table) do |pool|
        status = PoolStatus.new(pool)
        status.total_data_blocks.should == @size / 2 / @data_block_size
      end
    end
  end

  def test_extra_data_space_must_not_be_used_on_suspend
    with_dev(@tvm.table('data')) do |data|
      table = pool_table(@size / 2, data)

      with_dev(table) do |pool|
        @tvm.resize('data', @size)

        pool.pause do
          data.pause do
            data.load(@tvm.table('data'))
          end
        end

        status = PoolStatus.new(pool)
        status.total_data_blocks.should == @size / 2 / @data_block_size
      end
    end
  end

  def test_extra_data_space_must_not_be_used_on_reload
    with_dev(@tvm.table('data')) do |data|
      table = pool_table(@size / 2, data)

      with_dev(table) do |pool|
        @tvm.resize('data', @size)

        pool.pause do
          data.pause do
            data.load(@tvm.table('data'))
          end

          pool.load(table)
        end

        status = PoolStatus.new(pool)
        status.total_data_blocks.should == @size / 2 / @data_block_size
      end
    end
  end
end

#----------------------------------------------------------------

class PoolReloadWithSpaceTests < ThinpTestCase
  include Tags
  include Utils
  include TinyVolumeManager

  def setup
    super
    @low_water_mark = 0
    @data_block_size = 128
  end

  #--------------------------------

  tag :thinp_target

  def test_reload_no_io
    table = Table.new(ThinPoolTarget.new(@size, @metadata_dev, @data_dev,
                                         @data_block_size, @low_water_mark))

    with_dev(table) do |pool|
      pool.pause do
        pool.load(table)
      end
    end
  end

  def test_reload_io
    table = Table.new(ThinPoolTarget.new(20971520, @metadata_dev, @data_dev,
                                         @data_block_size, @low_water_mark))

    with_dev(table) do |pool|
      with_new_thin(pool, @volume_size, 0) do |thin|
        tid = Thread.new(thin) do |thin|
          wipe_device(thin)
        end

        ProcessControl.sleep 5

        # All thins must be paused before reloading the pool
        thin.pause do
          pool.pause do
            pool.load(table)
          end
        end

        tid.join
      end
    end
  end
end

#----------------------------------------------------------------

class PoolResizeWithSpaceTests < ThinpTestCase
  include Tags
  include Utils
  include TinyVolumeManager

  def setup
    super
    @low_water_mark = 0
    @data_block_size = 128
  end

  def pool_table(size)
    Table.new(ThinPoolTarget.new(size, @metadata_dev, @data_dev,
                                 @data_block_size, @low_water_mark))
  end

  #--------------------------------

  tag :thinp_target

  def test_resize
    target_step = @size / 8
    with_standard_pool(target_step) do |pool|
      2.upto(8) do |n|
        table = pool_table(n * target_step)
        pool.pause do
          pool.load(table)
        end
      end
    end
  end
end

#----------------------------------------------------------------

class PoolResizeWhenOutOfSpaceTests < ThinpTestCase
  include Tags
  include Utils
  include TinyVolumeManager

  def setup
    super
    @low_water_mark = 0
    @data_block_size = 128
  end

  def in_out_of_data_mode(pool)
      status = PoolStatus.new(pool)
      status.options[:mode] == :out_of_data_space
  end

  def wait_until_out_of_data(pool)
    pool.event_tracker.wait do
      in_out_of_data_mode(pool)
    end
  end

  def wipe_expecting_error(dev)
    failed = false
    begin
      wipe_device(dev)
    rescue
      failed = true
    end

    failed.should be_true
  end

  #--------------------------------

  tag :thinp_target

  def test_out_of_data_space_errors_immediately_if_requested
    with_standard_pool(@volume_size / 2, :error_if_no_space => true) do |pool|
      failed = false

      with_new_thin(pool, @volume_size, 0) do |thin|
        begin
          wipe_device(thin)
        rescue
          failed = true
        end
      end

      failed.should be_true
      status = PoolStatus.new(pool)
      status.options[:mode].should == :out_of_data_space
    end
  end

  def test_out_of_data_space_times_out
    with_standard_pool(@volume_size / 2, :error_if_no_space => false) do |pool|
      failed = false

      with_new_thin(pool, @volume_size, 0) do |thin|
        begin
          wipe_device(thin)
        rescue
          failed = true
        end
      end

      failed.should be_true
      status = PoolStatus.new(pool)
      status.options[:mode].should == :read_only

      # FIXME: the needs_check flag should _not_ be set.
    end
  end

  def test_resize_after_OODS_error_immediately
    tvm = VM.new
    tvm.add_allocation_volume(@data_dev, 0, dev_size(@data_dev))

    @size = @volume_size / 2
    tvm.add_volume(linear_vol('data', @volume_size / 2))

    with_dev(tvm.table('data')) do |data|
      wipe_device(@metadata_dev, 8)

      table = Table.new(ThinPoolTarget.new(@size, @metadata_dev, data,
                                           @data_block_size, @low_water_mark,
                                           true, true, true, false, true))

      with_dev(table) do |pool|
        with_new_thin(pool, @volume_size, 0) do |thin|
          wipe_expecting_error(thin)

          thin.pause_noflush do
            # new size of the pool/data device
            @size *= 4

            # resize the underlying data device
            tvm.resize('data', @size)
            data.pause do
              data.load(tvm.table('data'))
            end

            # resize the pool
            pool.pause do
              table2 = Table.new(ThinPoolTarget.new(@size, @metadata_dev, data,
                                                    @data_block_size, @low_water_mark,
                                                    true, true, true, false, true))
              pool.load(table2)
            end

            status = PoolStatus.new(pool)
            status.options[:mode].should == :read_write
          end
        end
      end
    end
  end

  def test_resize_after_OODS_held_io
    tvm = VM.new
    tvm.add_allocation_volume(@data_dev, 0, dev_size(@data_dev))

    @size = @volume_size / 2
    tvm.add_volume(linear_vol('data', @volume_size / 2))

    with_dev(tvm.table('data')) do |data|
      wipe_device(@metadata_dev, 8)

      table = Table.new(ThinPoolTarget.new(@size, @metadata_dev, data,
                                           @data_block_size, @low_water_mark))

      with_dev(table) do |pool|
        with_new_thin(pool, @volume_size, 0) do |thin|
          tid = Thread.new(thin) do |thin|
            # If this errors then the exception _will_ be reported
            wipe_device(thin)
          end

          wait_until_out_of_data(pool)

          thin.pause_noflush do
            # new size of the pool/data device
            @size *= 4

            in_out_of_data_mode(pool).should be_true

            # resize the underlying data device
            tvm.resize('data', @size)
            data.pause do
              data.load(tvm.table('data'))
            end

            # resize the pool
            pool.pause do
              table2 = Table.new(ThinPoolTarget.new(@size, @metadata_dev, data,
                                                    @data_block_size, @low_water_mark))
              pool.load(table2)
            end
          end

          tid.join
        end
      end
    end
  end

  # see BZ #769921
  def _test_ext4_runs_out_of_space
    # we create a pool with a really tiny data volume that wont be
    # able to complete a mkfs.
    with_standard_pool(16) do |pool|
      with_new_thin(pool, @volume_size, 0) do |thin|

        event_tracker = pool.event_tracker;

        thin_fs = FS::file_system(:ext4, thin)
        fork {thin_fs.format}

        # FIXME: this is so common it should go into a utility lib
        event_tracker.wait do
          status = PoolStatus.new(pool)
          status.used_data_blocks >= status.total_data_blocks - @low_water_mark
        end

        # we're not sure what the development version of dmeventd was
        # doing to create the issue; some experiments to find out.
        pool.info

        # Resize the pool so the format can complete
        table = Table.new(ThinPoolTarget.new(@size, @metadata_dev, @data_dev,
                                             @data_block_size, @low_water_mark))
        pool.load(table)
        pool.resume
      end
    end

    Process.wait
    if $?.exitstatus > 0
      raise RuntimeError, "wipe sub process failed"
    end
  end
end

#----------------------------------------------------------------
