module main

import net.s3
import os
import ui

const app_version = '0.4.0'
const download_chunk_size = i64(5 * 1024 * 1024) // 5 MiB
const upload_chunk_size = i64(5 * 1024 * 1024) // 5 MiB, S3 minimum multipart part size
const picker_page_size = 18
const picker_spacer_id = '__r2box_picker_spacer__'

struct ObjectDetailsJob {
	endpoint   string
	access_key string
	secret_key string
	bucket     string
	key        string
}

struct ObjectDetailsEvent {
	key           string
	size          i64
	last_modified string
	etag          string
	content_type  string
	error_message string
}

enum UploadEventKind {
	progress
	completed
	failed
	cancelled
}

struct UploadJob {
	endpoint   string
	access_key string
	secret_key string
	bucket     string
	key        string
	local_path string
	total      i64
}

struct UploadEvent {
	kind     UploadEventKind
	key      string
	uploaded i64
	total    i64
	message  string
}

enum DownloadEventKind {
	progress
	completed
	failed
	cancelled
}

struct DownloadJob {
	endpoint     string
	access_key   string
	secret_key   string
	bucket       string
	key          string
	destination  string
	partial_path string
}

struct DownloadEvent {
	kind        DownloadEventKind
	key         string
	destination string
	downloaded  i64
	total       i64
	message     string
}

struct DownloadSelection {
	key         string
	destination string
}

struct PickerEntry {
	id   string
	text string
}

struct ObjectEntry {
	key     string
	display string
	is_dir  bool
}

@[heap]
struct App {
mut:
	window &ui.Window = unsafe { nil }

	// Connection widgets
	endpoint_box   &ui.TextBox = unsafe { nil }
	access_key_box &ui.TextBox = unsafe { nil }
	secret_key_box &ui.TextBox = unsafe { nil }
	bucket_box     &ui.TextBox = unsafe { nil }

	// Object/action widgets
	objects_box            &ui.ListBox = unsafe { nil }
	filter_box             &ui.TextBox = unsafe { nil }
	path_label             &ui.Label   = unsafe { nil }
	page_label             &ui.Label   = unsafe { nil }
	object_key_box         &ui.TextBox = unsafe { nil }
	upload_path_box        &ui.TextBox = unsafe { nil }
	upload_selection_label &ui.Label   = unsafe { nil }
	download_to_box        &ui.TextBox = unsafe { nil }
	delete_box             &ui.TextBox = unsafe { nil }

	// Object details widget: deliberately a non-interactive Label.
	// Avoid adding another TextBox/ScrollView event receiver on pinned V UI.
	object_details_label &ui.Label = unsafe { nil }

	// Upload queue / progress widgets
	upload_queue_label    &ui.Label       = unsafe { nil }
	upload_progress       &ui.ProgressBar = unsafe { nil }
	upload_progress_label &ui.Label       = unsafe { nil }

	// Download queue / progress widgets
	download_selection_label &ui.Label       = unsafe { nil }
	download_queue_label     &ui.Label       = unsafe { nil }
	download_progress        &ui.ProgressBar = unsafe { nil }
	download_progress_label  &ui.Label       = unsafe { nil }

	// Local file picker widgets
	picker_list         &ui.ListBox = unsafe { nil }
	picker_path_label   &ui.Label   = unsafe { nil }
	picker_page_label   &ui.Label   = unsafe { nil }
	picker_status_label &ui.Label   = unsafe { nil }

	// Connection state
	endpoint   string
	access_key string
	secret_key string
	bucket     string

	// Object browser state
	object_filter   string
	current_prefix  string
	all_objects     []ObjectEntry
	page_index      int
	page_tokens     []string
	next_page_token string

	// Local file picker state
	picker_dir         string
	picker_selected_id string
	picker_entries     []PickerEntry
	picker_page        int

	// File operations
	local_upload        string
	staged_upload_files []string
	object_key          string
	download_to         string
	delete_confirm      string

	// Background object details state
	object_details_events chan ObjectDetailsEvent

	// Background upload queue state
	upload_events           chan UploadEvent
	upload_cancel           chan bool
	upload_active           bool
	upload_cancel_requested bool
	upload_queue            []UploadJob
	upload_queue_index      int
	upload_completed        int
	upload_failed           int
	upload_failed_jobs      []UploadJob

	// Background download queue state
	download_events           chan DownloadEvent
	download_cancel           chan bool
	download_active           bool
	download_cancel_requested bool
	staged_downloads          []DownloadSelection
	download_queue            []DownloadJob
	download_queue_index      int
	download_completed        int
	download_failed           int
	download_failed_jobs      []DownloadJob

	// Status
	status       string
	status_label &ui.Label = unsafe { nil }
}

fn main() {
	mut app := &App{
		endpoint:              'https://<ACCOUNT_ID>.r2.cloudflarestorage.com'
		status:                'Not connected'
		page_tokens:           ['']
		object_details_events: chan ObjectDetailsEvent{cap: 16}
		upload_events:         chan UploadEvent{cap: 64}
		upload_cancel:         chan bool{cap: 1}
		download_events:       chan DownloadEvent{cap: 64}
		download_cancel:       chan bool{cap: 1}
	}

	// Connection fields. Every textbox has an explicit ID and is kept as a
	// reference so programmatic updates can use TextBox.set_text().
	app.endpoint_box = ui.textbox(
		id:          'endpoint'
		width:       340
		placeholder: 'S3 endpoint'
		text:        &app.endpoint
	)

	app.access_key_box = ui.textbox(
		id:          'access-key'
		width:       340
		placeholder: 'Access Key ID'
		text:        &app.access_key
	)

	app.secret_key_box = ui.textbox(
		id:          'secret-key'
		width:       340
		placeholder: 'Secret Access Key'
		is_password: true
		text:        &app.secret_key
	)

	app.bucket_box = ui.textbox(
		id:          'bucket'
		width:       340
		placeholder: 'Bucket name'
		text:        &app.bucket
	)

	app.filter_box = ui.textbox(
		id:          'object-filter'
		width:       460
		placeholder: 'Filter current page, then press Enter'
		text:        &app.object_filter
		on_enter:    app.filter_enter
	)

	app.object_key_box = ui.textbox(
		id:          'object-key'
		width:       340
		placeholder: 'Object key, e.g. backup/photo.jpg'
		text:        &app.object_key
	)

	app.upload_path_box = ui.textbox(
		id:          'upload-path'
		width:       340
		placeholder: 'Local file path to upload'
		text:        &app.local_upload
	)

	app.download_to_box = ui.textbox(
		id:          'download-to'
		width:       340
		placeholder: 'Auto: your Downloads folder'
		text:        &app.download_to
	)

	app.delete_box = ui.textbox(
		id:          'delete-confirm'
		width:       340
		placeholder: 'Type DELETE to confirm'
		text:        &app.delete_confirm
	)

	// Object listing uses ListBox instead of a multiline TextBox. ListBox only
	// draws the visible rows while scrolling, which is much better suited for
	// buckets containing hundreds of objects.
	app.objects_box = ui.listbox(
		id:         'objects'
		width:      620
		height:     335
		scrollview: true
		on_change:  app.object_selected
		items:      map[string]string{}
	)

	app.object_details_label = ui.label(
		id:     'object-details'
		width:  620
		height: 145
		text:   'Object details\nSelect an object to view details.'
	)

	app.path_label = ui.label(
		text: 'Path: /'
	)

	app.page_label = ui.label(
		text: 'Page 1'
	)

	app.upload_queue_label = ui.label(
		text: 'Upload queue: idle'
	)

	app.upload_progress_label = ui.label(
		text: 'Upload: idle'
	)

	app.upload_progress = ui.progressbar(
		id:     'upload-progress'
		width:  1080
		height: 14
		min:    0
		max:    100
		val:    0
	)

	app.upload_selection_label = ui.label(
		text: 'Local files staged: 0'
	)

	app.download_selection_label = ui.label(
		text: 'Downloads staged: 0'
	)

	app.download_queue_label = ui.label(
		text: 'Download queue: idle'
	)

	app.download_progress_label = ui.label(
		text: 'Download: idle'
	)

	app.download_progress = ui.progressbar(
		id:     'download-progress'
		width:  1080
		height: 14
		min:    0
		max:    100
		val:    0
	)

	app.status_label = ui.label(
		text: app.status
	)

	app.window = ui.window(
		width:                        1120
		height:                       800
		title:                        'R2Box ${app_version}'
		resizable:                    false
		on_draw:                      app.poll_transfer_events
		on_files_dropped:             app.files_dropped
		enable_dragndrop:             true
		max_dropped_files:            16
		max_dropped_file_path_length: 4096
		children:                     [
			ui.column(
				margin:   ui.Margin{16, 16, 16, 16}
				spacing:  10
				heights:  [ui.compact, ui.stretch, ui.compact]
				children: [
					ui.label(
						text: 'R2Box ${app_version} — Cloudflare R2 / S3 client'
					),
					ui.row(
						spacing:  18
						widths:   [430.0, ui.stretch]
						children: [
							ui.column(
								spacing:  9
								children: [
									ui.label(text: 'Connection'),
									ui.row(
										spacing:  8
										widths:   [ui.stretch, ui.compact]
										children: [app.endpoint_box,
											ui.button(
												text:     'Paste'
												on_click: app.paste_endpoint_click
											)]
									),
									ui.row(
										spacing:  8
										widths:   [ui.stretch, ui.compact]
										children: [app.access_key_box,
											ui.button(
												text:     'Paste'
												on_click: app.paste_access_key_click
											)]
									),
									ui.row(
										spacing:  8
										widths:   [ui.stretch, ui.compact]
										children: [app.secret_key_box,
											ui.button(
												text:     'Paste'
												on_click: app.paste_secret_key_click
											)]
									),
									ui.row(
										spacing:  8
										widths:   [ui.stretch, ui.compact]
										children: [app.bucket_box,
											ui.button(
												text:     'Paste'
												on_click: app.paste_bucket_click
											)]
									),
									ui.button(
										text:     'Connect / Refresh'
										on_click: app.refresh_click
									),
									ui.label(text: 'Object actions'),
									ui.row(
										spacing:  8
										widths:   [ui.stretch, ui.compact]
										children: [app.object_key_box,
											ui.button(
												text:     'Paste'
												on_click: app.paste_object_key_click
											)]
									),
									ui.row(
										spacing:  8
										widths:   [ui.stretch, ui.compact, ui.compact, ui.compact]
										children: [app.upload_path_box,
											ui.button(
												text:     'Browse'
												on_click: app.browse_upload_click
											),
											ui.button(
												text:     'Upload'
												on_click: app.upload_click
											),
											ui.button(
												text:     'Cancel'
												on_click: app.cancel_upload_click
											)]
									),
									ui.row(
										spacing:  8
										widths:   [ui.stretch, ui.compact, ui.compact]
										children: [app.upload_selection_label,
											ui.button(
												text:     'Clear staged'
												on_click: app.clear_staged_uploads_click
											),
											ui.button(
												text:     'Retry failed'
												on_click: app.retry_failed_uploads_click
											)]
									),
									ui.row(
										spacing:  8
										widths:   [ui.stretch, ui.compact]
										children: [app.download_to_box,
											ui.button(
												text:     'Paste'
												on_click: app.paste_download_to_click
											)]
									),
									ui.row(
										spacing:  8
										widths:   [ui.stretch, ui.compact, ui.compact, ui.compact]
										children: [app.download_selection_label,
											ui.button(
												text:     'Add'
												on_click: app.add_download_click
											),
											ui.button(
												text:     'Clear'
												on_click: app.clear_staged_downloads_click
											),
											ui.button(
												text:     'Retry failed'
												on_click: app.retry_failed_downloads_click
											)]
									),
									ui.row(
										spacing:  8
										widths:   [ui.stretch, ui.compact, ui.compact]
										children: [ui.label(text: 'Download queue actions'),
											ui.button(
												text:     'Download'
												on_click: app.download_click
											),
											ui.button(
												text:     'Cancel'
												on_click: app.cancel_download_click
											)]
									),
									ui.row(
										spacing:  8
										widths:   [ui.stretch, ui.compact]
										children: [app.delete_box,
											ui.button(
												text:     'Delete object'
												on_click: app.delete_click
											)]
									),
								]
							),
							ui.column(
								spacing:  8
								heights:  [
									ui.compact,
									ui.compact,
									ui.compact,
									ui.compact,
									ui.stretch,
									ui.compact,
								]
								children: [
									ui.label(text: 'Objects'),
									ui.row(
										spacing:  8
										widths:   [ui.stretch, ui.compact, ui.compact]
										children: [app.path_label,
											ui.button(
												text:     'Up'
												on_click: app.up_click
											),
											ui.button(
												text:     'Root'
												on_click: app.root_click
											)]
									),
									ui.row(
										spacing:  8
										widths:   [ui.stretch, ui.compact, ui.compact]
										children: [app.filter_box,
											ui.button(
												text:     'Filter'
												on_click: app.filter_click
											),
											ui.button(
												text:     'Clear'
												on_click: app.clear_filter_click
											)]
									),
									ui.row(
										spacing:  8
										widths:   [ui.stretch, ui.compact, ui.compact]
										children: [app.page_label,
											ui.button(
												text:     'Previous'
												on_click: app.previous_page_click
											),
											ui.button(
												text:     'Next'
												on_click: app.next_page_click
											)]
									),
									app.objects_box,
									app.object_details_label,
								]
							),
						]
					),
					ui.column(
						spacing:  4
						children: [
							app.upload_queue_label,
							app.upload_progress_label,
							app.upload_progress,
							app.download_queue_label,
							app.download_progress_label,
							app.download_progress,
							app.status_label,
						]
					),
				]
			),
		]
	)

	ui.run(app.window)
}

fn cancel_requested(cancel chan bool) bool {
	mut requested := false

	select {
		_ := <-cancel {
			requested = true
		}
		else {}
	}

	return requested
}

fn object_size_text(bytes i64) string {
	if bytes < 1024 {
		return '${bytes} B'
	}

	kib := i64(1024)
	mib := i64(1024 * 1024)
	gib := i64(1024 * 1024 * 1024)

	if bytes < mib {
		whole := bytes / kib
		tenths := ((bytes % kib) * 10) / kib
		return '${whole}.${tenths} KiB (${bytes} bytes)'
	}

	if bytes < gib {
		whole := bytes / mib
		tenths := ((bytes % mib) * 10) / mib
		return '${whole}.${tenths} MiB (${bytes} bytes)'
	}

	whole := bytes / gib
	tenths := ((bytes % gib) * 10) / gib
	return '${whole}.${tenths} GiB (${bytes} bytes)'
}

fn (mut app App) show_object_details_loading(key string) {
	app.object_details_label.set_text('Object details\nLoading metadata...\nKey: ${key}')
}

fn (mut app App) apply_object_details(event ObjectDetailsEvent) {
	// Ignore a late response if the user selected another object meanwhile.
	if app.object_key.trim_space() != event.key {
		return
	}

	if event.error_message != '' {
		app.object_details_label.set_text('Object details\nCannot load object metadata.\nKey: ${event.key}\nError: ${event.error_message}')
		return
	}

	name := os.file_name(event.key)
	content_type := if event.content_type == '' { '(not provided)' } else { event.content_type }
	modified := if event.last_modified == '' { '(not provided)' } else { event.last_modified }
	etag := if event.etag == '' { '(not provided)' } else { event.etag }

	app.object_details_label.set_text('Object details\nName: ${name}\nSize: ${object_size_text(event.size)}\nContent-Type: ${content_type}\nLast Modified: ${modified}\nETag: ${etag}\nKey: ${event.key}')
}

fn mib_text(bytes i64) string {
	mib := i64(1024 * 1024)

	whole := bytes / mib
	tenths := ((bytes % mib) * 10) / mib
	return '${whole}.${tenths} MiB'
}

fn progress_percent(downloaded i64, total i64) int {
	if total <= 0 {
		return 0
	}

	mut value := int((downloaded * 100) / total)
	if value < 0 {
		value = 0
	}
	if value > 100 {
		value = 100
	}
	return value
}

fn (mut app App) update_upload_queue_label() {
	total := app.upload_queue.len

	if total == 0 {
		app.upload_queue_label.set_text('Upload queue: idle')
		return
	}

	if !app.upload_active && app.upload_queue_index >= total {
		app.upload_queue_label.set_text('Upload queue: done — ${app.upload_completed} complete, ${app.upload_failed} failed')
		return
	}

	current := if app.upload_queue_index < total {
		app.upload_queue_index + 1
	} else {
		total
	}

	name := if app.upload_queue_index < total {
		os.file_name(app.upload_queue[app.upload_queue_index].local_path)
	} else {
		''
	}

	app.upload_queue_label.set_text('Upload queue: ${current}/${total} — ${name} — ${app.upload_completed} complete, ${app.upload_failed} failed')
}

fn (mut app App) preserve_remaining_uploads(start_index int) {
	mut remaining := []string{}

	if start_index < app.upload_queue.len {
		for i in start_index .. app.upload_queue.len {
			path := app.upload_queue[i].local_path
			if path !in remaining {
				remaining << path
			}
		}
	}

	app.staged_upload_files = remaining
	app.update_upload_selection_label()

	if start_index < app.upload_queue.len {
		job := app.upload_queue[start_index]
		app.upload_path_box.set_text(job.local_path)
		app.upload_path_box.cursor_pos = job.local_path.runes().len
		app.upload_path_box.insert('')

		app.object_key_box.set_text(job.key)
		app.object_key_box.cursor_pos = job.key.runes().len
		app.object_key_box.insert('')
	} else {
		app.upload_path_box.set_text('')
		app.object_key_box.set_text('')
	}
}

fn (mut app App) stop_upload_queue_cancelled(next_index int, message string) {
	app.upload_active = false
	app.upload_cancel_requested = false
	app.upload_queue_index = next_index

	app.preserve_remaining_uploads(next_index)

	remaining := if next_index < app.upload_queue.len {
		app.upload_queue.len - next_index
	} else {
		0
	}

	app.upload_queue_label.set_text('Upload queue: cancelled — ${app.upload_completed} complete, ${remaining} remaining')
	app.upload_progress_label.set_text('Upload: cancelled')
	app.set_status(message)

	// Completed objects may have changed the active listing.
	app.reset_pagination()
	app.refresh_objects()
}

fn (mut app App) cancel_upload_click(_ &ui.Button) {
	if !app.upload_active {
		app.set_status('No upload queue is running.')
		return
	}

	if app.upload_cancel_requested {
		app.set_status('Upload cancellation is already requested.')
		return
	}

	app.upload_cancel_requested = true

	// The channel is buffered and each job gets a fresh channel. select/else
	// keeps the UI callback non-blocking even if the worker is between checks.
	select {
		app.upload_cancel <- true {}
		else {}
	}

	app.upload_progress_label.set_text('Upload: cancel requested...')
	app.set_status('Cancel requested. Waiting for the current upload request/chunk to stop.')
}

fn (mut app App) retry_failed_uploads_click(_ &ui.Button) {
	if app.upload_active || app.download_active {
		app.set_status('Wait for the active transfer queue to finish before retrying uploads.')
		return
	}

	if !app.validate_connection() {
		return
	}

	if app.upload_failed_jobs.len == 0 {
		app.set_status('No failed uploads are available to retry.')
		return
	}

	failed := app.upload_failed_jobs.clone()
	mut retry_queue := []UploadJob{cap: failed.len}

	// Validate everything before replacing the saved failed-job list.
	for old_job in failed {
		if !os.is_file(old_job.local_path) {
			app.set_status('Cannot retry uploads: local file no longer exists: ${old_job.local_path}')
			return
		}

		stat_local := os.stat(old_job.local_path) or {
			app.set_status('Cannot retry uploads: cannot read ${old_job.local_path}: ${err.msg()}')
			return
		}

		retry_queue << UploadJob{
			endpoint:   app.endpoint.trim_space()
			access_key: app.access_key.trim_space()
			secret_key: app.secret_key
			bucket:     app.bucket.trim_space()
			key:        old_job.key
			local_path: old_job.local_path
			total:      i64(stat_local.size)
		}
	}

	if retry_queue.len == 0 {
		app.set_status('No failed uploads are available to retry.')
		return
	}

	app.upload_queue = retry_queue
	app.upload_failed_jobs.clear()
	app.upload_queue_index = 0
	app.upload_completed = 0
	app.upload_failed = 0
	app.upload_cancel_requested = false

	app.staged_upload_files.clear()
	for job in app.upload_queue {
		if job.local_path !in app.staged_upload_files {
			app.staged_upload_files << job.local_path
		}
	}
	app.update_upload_selection_label()

	first_job := app.upload_queue[0]
	app.upload_path_box.set_text(first_job.local_path)
	app.upload_path_box.cursor_pos = first_job.local_path.runes().len
	app.upload_path_box.insert('')

	app.object_key_box.set_text(first_job.key)
	app.object_key_box.cursor_pos = first_job.key.runes().len
	app.object_key_box.insert('')

	app.upload_active = true
	app.upload_progress.val = 0
	app.update_upload_queue_label()
	app.set_status('Retrying ${app.upload_queue.len} failed upload(s).')

	app.start_current_upload_job()
}

fn (mut app App) start_current_upload_job() {
	if app.upload_queue_index >= app.upload_queue.len {
		app.finish_upload_queue()
		return
	}

	job := app.upload_queue[app.upload_queue_index]

	app.upload_cancel = chan bool{cap: 1}
	app.upload_progress.val = 0
	app.upload_progress_label.set_text('Upload: preparing ${os.file_name(job.local_path)}...')
	app.update_upload_queue_label()
	app.set_status('Uploading ${app.upload_queue_index + 1}/${app.upload_queue.len}: ${job.key}')

	spawn upload_worker(job, app.upload_events, app.upload_cancel)
}

fn (mut app App) finish_upload_queue() {
	total := app.upload_queue.len
	app.upload_active = false
	app.upload_cancel_requested = false
	app.upload_queue_index = total

	app.staged_upload_files.clear()
	app.update_upload_selection_label()
	app.update_upload_queue_label()

	// Clear the single-file preview after the whole queue is finished.
	app.upload_path_box.set_text('')
	app.object_key_box.set_text('')

	// One refresh after the complete queue is cheaper and avoids repeatedly
	// rebuilding the browser between files.
	app.reset_pagination()
	app.refresh_objects()

	if app.upload_failed == 0 {
		app.upload_progress.val = 100
		app.upload_progress_label.set_text('Upload: queue complete')
		app.set_status('Upload queue complete: ${app.upload_completed}/${total} uploaded.')
	} else {
		app.upload_progress_label.set_text('Upload: queue finished with ${app.upload_failed} failure(s)')
		app.set_status('Upload queue finished: ${app.upload_completed} complete, ${app.upload_failed} failed. Retry failed is available.')
	}
}

fn (mut app App) apply_upload_event(event UploadEvent) {
	match event.kind {
		.progress {
			percent := progress_percent(event.uploaded, event.total)
			app.upload_progress.val = percent
			app.upload_progress_label.set_text('Upload: ${percent}% — ${mib_text(event.uploaded)} / ${mib_text(event.total)}')
			app.status_label.set_text('Uploading ${app.upload_queue_index + 1}/${app.upload_queue.len}: ${event.key}')
		}
		.completed {
			app.upload_progress.val = 100
			app.upload_progress_label.set_text('Upload: complete — ${mib_text(event.total)}')

			app.upload_completed++
			app.upload_queue_index++

			if app.upload_cancel_requested {
				app.stop_upload_queue_cancelled(app.upload_queue_index,
					'Upload cancellation took effect after the current object completed.')
			} else if app.upload_queue_index < app.upload_queue.len {
				app.start_current_upload_job()
			} else {
				app.finish_upload_queue()
			}
		}
		.failed {
			percent := progress_percent(event.uploaded, event.total)
			app.upload_progress.val = percent

			if event.total > 0 {
				app.upload_progress_label.set_text('Upload: failed at ${percent}% — ${mib_text(event.uploaded)} / ${mib_text(event.total)}')
			} else {
				app.upload_progress_label.set_text('Upload: failed')
			}

			if app.upload_queue_index < app.upload_queue.len {
				app.upload_failed_jobs << app.upload_queue[app.upload_queue_index]
			}

			app.upload_failed++
			app.upload_queue_index++

			if app.upload_cancel_requested {
				app.stop_upload_queue_cancelled(app.upload_queue_index,
					'Upload queue stopped after the current upload failed while cancellation was requested.')
			} else if app.upload_queue_index < app.upload_queue.len {
				// Normal failures continue the queue. Failed jobs are retained
				// for Stage 6 Retry.
				app.start_current_upload_job()
			} else {
				app.finish_upload_queue()
			}
		}
		.cancelled {
			current := app.upload_queue_index
			app.stop_upload_queue_cancelled(current, if event.message == '' {
				'Upload cancelled.'
			} else {
				event.message
			})
		}
	}
}

fn (mut app App) update_download_selection_label() {
	app.download_selection_label.set_text('Downloads staged: ${app.staged_downloads.len}')
}

fn (mut app App) update_download_queue_label() {
	total := app.download_queue.len

	if total == 0 {
		app.download_queue_label.set_text('Download queue: idle')
		return
	}

	if !app.download_active && app.download_queue_index >= total {
		app.download_queue_label.set_text('Download queue: done — ${app.download_completed} complete, ${app.download_failed} failed')
		return
	}

	current := if app.download_queue_index < total {
		app.download_queue_index + 1
	} else {
		total
	}

	name := if app.download_queue_index < total {
		os.file_name(app.download_queue[app.download_queue_index].key)
	} else {
		''
	}

	app.download_queue_label.set_text('Download queue: ${current}/${total} — ${name} — ${app.download_completed} complete, ${app.download_failed} failed')
}

fn resolve_download_destination(key string, requested string) string {
	mut destination := requested.trim_space()

	if destination == '' {
		return default_download_path(key)
	}

	if os.is_dir(destination) {
		return os.join_path(destination, os.file_name(key))
	}

	return destination
}

fn (mut app App) stage_download(key string, requested_destination string) bool {
	clean_key := key.trim_space()
	if clean_key == '' {
		app.set_status('Error: object key is empty.')
		return false
	}

	destination := resolve_download_destination(clean_key, requested_destination)
	parent_dir := os.dir(destination)

	if !os.is_dir(parent_dir) {
		app.set_status('Download folder does not exist: ${parent_dir}')
		return false
	}

	if os.exists(destination) {
		app.set_status('Cannot stage download: destination already exists.')
		return false
	}

	for item in app.staged_downloads {
		if item.key == clean_key {
			app.set_status('This object is already staged for download.')
			return false
		}

		if item.destination == destination {
			app.set_status('Cannot stage download: another object uses the same local destination.')
			return false
		}
	}

	app.staged_downloads << DownloadSelection{
		key:         clean_key
		destination: destination
	}

	app.download_to_box.set_text(destination)
	app.download_to_box.cursor_pos = destination.runes().len
	app.download_to_box.insert('')

	app.update_download_selection_label()
	app.set_status('Staged download ${app.staged_downloads.len}: ${clean_key} → ${destination}')
	return true
}

fn (mut app App) add_download_click(_ &ui.Button) {
	if app.download_active {
		app.set_status('Cannot add items while the download queue is running.')
		return
	}

	if app.upload_active {
		app.set_status('Wait for the upload queue to finish before staging downloads.')
		return
	}

	if !app.validate_connection() {
		return
	}

	app.stage_download(app.object_key, app.download_to)
}

fn (mut app App) clear_staged_downloads_click(_ &ui.Button) {
	if app.download_active {
		app.set_status('Cannot clear staged downloads while the queue is running.')
		return
	}

	app.staged_downloads.clear()
	app.update_download_selection_label()
	app.download_queue.clear()
	app.download_queue_index = 0
	app.download_completed = 0
	app.download_failed = 0
	app.download_failed_jobs.clear()
	app.update_download_queue_label()
	app.set_status('Staged downloads cleared.')
}

fn (mut app App) fail_current_download_before_start(message string) {
	if app.download_queue_index < app.download_queue.len {
		app.download_failed_jobs << app.download_queue[app.download_queue_index]
	}

	app.download_failed++
	app.download_queue_index++
	app.download_progress_label.set_text('Download: skipped / failed')
	app.set_status(message)

	if app.download_queue_index < app.download_queue.len {
		app.start_current_download_job()
	} else {
		app.finish_download_queue()
	}
}

fn (mut app App) preserve_remaining_downloads(start_index int) {
	mut remaining := []DownloadSelection{}

	if start_index < app.download_queue.len {
		for i in start_index .. app.download_queue.len {
			job := app.download_queue[i]
			remaining << DownloadSelection{
				key:         job.key
				destination: job.destination
			}
		}
	}

	app.staged_downloads = remaining
	app.update_download_selection_label()

	if start_index < app.download_queue.len {
		job := app.download_queue[start_index]
		app.object_key_box.set_text(job.key)
		app.object_key_box.cursor_pos = job.key.runes().len
		app.object_key_box.insert('')

		app.download_to_box.set_text(job.destination)
		app.download_to_box.cursor_pos = job.destination.runes().len
		app.download_to_box.insert('')
	}
}

fn (mut app App) stop_download_queue_cancelled(next_index int, message string) {
	app.download_active = false
	app.download_cancel_requested = false
	app.download_queue_index = next_index

	app.preserve_remaining_downloads(next_index)

	remaining := if next_index < app.download_queue.len {
		app.download_queue.len - next_index
	} else {
		0
	}

	app.download_queue_label.set_text('Download queue: cancelled — ${app.download_completed} complete, ${remaining} remaining')
	app.download_progress_label.set_text('Download: cancelled')
	app.set_status(message)
}

fn (mut app App) cancel_download_click(_ &ui.Button) {
	if !app.download_active {
		app.set_status('No download queue is running.')
		return
	}

	if app.download_cancel_requested {
		app.set_status('Download cancellation is already requested.')
		return
	}

	app.download_cancel_requested = true

	select {
		app.download_cancel <- true {}
		else {}
	}

	app.download_progress_label.set_text('Download: cancel requested...')
	app.set_status('Cancel requested. Waiting for the current download chunk/request to stop.')
}

fn (mut app App) retry_failed_downloads_click(_ &ui.Button) {
	if app.download_active || app.upload_active {
		app.set_status('Wait for the active transfer queue to finish before retrying downloads.')
		return
	}

	if !app.validate_connection() {
		return
	}

	if app.download_failed_jobs.len == 0 {
		app.set_status('No failed downloads are available to retry.')
		return
	}

	failed := app.download_failed_jobs.clone()
	mut retry_queue := []DownloadJob{cap: failed.len}

	// Rebuild jobs with the current credentials while preserving the exact
	// object key and local destination from the failed attempt.
	for old_job in failed {
		parent_dir := os.dir(old_job.destination)
		if !os.is_dir(parent_dir) {
			app.set_status('Cannot retry downloads: folder no longer exists: ${parent_dir}')
			return
		}

		retry_queue << DownloadJob{
			endpoint:     app.endpoint.trim_space()
			access_key:   app.access_key.trim_space()
			secret_key:   app.secret_key
			bucket:       app.bucket.trim_space()
			key:          old_job.key
			destination:  old_job.destination
			partial_path: '${old_job.destination}.part'
		}
	}

	if retry_queue.len == 0 {
		app.set_status('No failed downloads are available to retry.')
		return
	}

	app.download_queue = retry_queue
	app.download_failed_jobs.clear()
	app.download_queue_index = 0
	app.download_completed = 0
	app.download_failed = 0
	app.download_cancel_requested = false

	app.staged_downloads.clear()
	for job in app.download_queue {
		app.staged_downloads << DownloadSelection{
			key:         job.key
			destination: job.destination
		}
	}
	app.update_download_selection_label()

	first_job := app.download_queue[0]
	app.object_key_box.set_text(first_job.key)
	app.object_key_box.cursor_pos = first_job.key.runes().len
	app.object_key_box.insert('')

	app.download_to_box.set_text(first_job.destination)
	app.download_to_box.cursor_pos = first_job.destination.runes().len
	app.download_to_box.insert('')

	app.download_active = true
	app.download_progress.val = 0
	app.update_download_queue_label()
	app.set_status('Retrying ${app.download_queue.len} failed download(s).')

	app.start_current_download_job()
}

fn (mut app App) start_current_download_job() {
	if app.download_queue_index >= app.download_queue.len {
		app.finish_download_queue()
		return
	}

	job := app.download_queue[app.download_queue_index]

	app.download_cancel = chan bool{cap: 1}

	if os.exists(job.destination) {
		app.fail_current_download_before_start('Skipping ${job.key}: destination already exists.')
		return
	}

	parent_dir := os.dir(job.destination)
	if !os.is_dir(parent_dir) {
		app.fail_current_download_before_start('Skipping ${job.key}: download folder does not exist: ${parent_dir}')
		return
	}

	if os.exists(job.partial_path) {
		os.rm(job.partial_path) or {
			app.fail_current_download_before_start('Skipping ${job.key}: cannot replace old partial file: ${err.msg()}')
			return
		}
	}

	app.download_progress.val = 0
	app.download_progress_label.set_text('Download: preparing ${os.file_name(job.key)}...')
	app.update_download_queue_label()
	app.set_status('Downloading ${app.download_queue_index + 1}/${app.download_queue.len}: ${job.key}')

	spawn download_worker(job, app.download_events, app.download_cancel)
}

fn (mut app App) finish_download_queue() {
	total := app.download_queue.len

	app.download_active = false
	app.download_cancel_requested = false
	app.download_queue_index = total

	app.staged_downloads.clear()
	app.update_download_selection_label()
	app.update_download_queue_label()

	if app.download_failed == 0 {
		app.download_progress.val = 100
		app.download_progress_label.set_text('Download: queue complete')
		app.set_status('Download queue complete: ${app.download_completed}/${total} downloaded.')
	} else {
		app.download_progress_label.set_text('Download: queue finished with ${app.download_failed} failure(s)')
		app.set_status('Download queue finished: ${app.download_completed} complete, ${app.download_failed} failed. Retry failed is available.')
	}
}

fn (mut app App) apply_download_event(event DownloadEvent) {
	match event.kind {
		.progress {
			percent := progress_percent(event.downloaded, event.total)
			app.download_progress.val = percent
			app.download_progress_label.set_text('Download: ${percent}% — ${mib_text(event.downloaded)} / ${mib_text(event.total)}')
			app.status_label.set_text('Downloading ${app.download_queue_index + 1}/${app.download_queue.len}: ${event.key}')
		}
		.completed {
			app.download_progress.val = 100
			app.download_progress_label.set_text('Download: complete — ${mib_text(event.total)}')

			app.download_completed++
			app.download_queue_index++

			if app.download_cancel_requested {
				app.stop_download_queue_cancelled(app.download_queue_index,
					'Download cancellation took effect after the current object completed.')
			} else if app.download_queue_index < app.download_queue.len {
				app.start_current_download_job()
			} else {
				app.finish_download_queue()
			}
		}
		.failed {
			percent := progress_percent(event.downloaded, event.total)
			app.download_progress.val = percent

			if event.total > 0 {
				app.download_progress_label.set_text('Download: failed at ${percent}% — ${mib_text(event.downloaded)} / ${mib_text(event.total)}')
			} else {
				app.download_progress_label.set_text('Download: failed')
			}

			if app.download_queue_index < app.download_queue.len {
				app.download_failed_jobs << app.download_queue[app.download_queue_index]
			}

			app.download_failed++
			app.download_queue_index++

			if app.download_cancel_requested {
				app.stop_download_queue_cancelled(app.download_queue_index,
					'Download queue stopped after the current download failed while cancellation was requested.')
			} else if app.download_queue_index < app.download_queue.len {
				// Normal failures keep the queue moving. Failed jobs remain
				// available for Stage 6 Retry.
				app.start_current_download_job()
			} else {
				app.finish_download_queue()
			}
		}
		.cancelled {
			current := app.download_queue_index
			app.stop_download_queue_cancelled(current, if event.message == '' {
				'Download cancelled. Partial file kept when data had already been written.'
			} else {
				event.message
			})
		}
	}
}

fn (mut app App) poll_transfer_events(_ &ui.Window) {
	mut changed := false

	for {
		select {
			event := <-app.object_details_events {
				app.apply_object_details(event)
				changed = true
			}
			else {
				break
			}
		}
	}

	for {
		select {
			event := <-app.upload_events {
				app.apply_upload_event(event)
				changed = true
			}
			else {
				break
			}
		}
	}

	for {
		select {
			event := <-app.download_events {
				app.apply_download_event(event)
				changed = true
			}
			else {
				break
			}
		}
	}

	if changed {
		app.window.refresh()
	}
}

fn read_clipboard() string {
	result := os.execute('xclip -selection clipboard -o')
	if result.exit_code != 0 {
		return ''
	}
	return result.output.trim_space()
}

fn (mut app App) paste_endpoint_click(_ &ui.Button) {
	value := read_clipboard()
	if value == '' {
		app.set_status('Clipboard is empty or xclip failed.')
		return
	}
	app.endpoint_box.set_text(value)
	app.endpoint_box.cursor_pos = value.runes().len
	app.endpoint_box.insert('')
	app.set_status('Endpoint pasted.')
}

fn (mut app App) paste_access_key_click(_ &ui.Button) {
	value := read_clipboard()
	if value == '' {
		app.set_status('Clipboard is empty or xclip failed.')
		return
	}
	app.access_key_box.set_text(value)
	app.access_key_box.cursor_pos = value.runes().len
	app.access_key_box.insert('')
	app.set_status('Access Key pasted.')
}

fn (mut app App) paste_secret_key_click(_ &ui.Button) {
	value := read_clipboard()
	if value == '' {
		app.set_status('Clipboard is empty or xclip failed.')
		return
	}
	app.secret_key_box.set_text(value)
	app.secret_key_box.cursor_pos = value.runes().len
	app.secret_key_box.insert('')
	app.set_status('Secret Key pasted.')
}

fn (mut app App) paste_bucket_click(_ &ui.Button) {
	value := read_clipboard()
	if value == '' {
		app.set_status('Clipboard is empty or xclip failed.')
		return
	}
	app.bucket_box.set_text(value)
	app.bucket_box.cursor_pos = value.runes().len
	app.bucket_box.insert('')
	app.set_status('Bucket pasted.')
}

fn (mut app App) paste_object_key_click(_ &ui.Button) {
	value := read_clipboard()
	if value == '' {
		app.set_status('Clipboard is empty or xclip failed.')
		return
	}
	app.object_key_box.set_text(value)
	app.object_key_box.cursor_pos = value.runes().len
	app.object_key_box.insert('')
	app.set_status('Object key pasted.')
}

fn (mut app App) paste_download_to_click(_ &ui.Button) {
	value := read_clipboard()
	if value == '' {
		app.set_status('Clipboard is empty or xclip failed.')
		return
	}
	app.download_to_box.set_text(value)
	app.download_to_box.cursor_pos = value.runes().len
	app.download_to_box.insert('')
	app.set_status('Download path pasted.')
}

fn (mut app App) close_file_picker() {
	if unsafe { app.window.child_window == 0 } {
		return
	}

	// This mirrors V UI's own Escape handling for child windows.
	for mut child in app.window.child_window.children {
		child.cleanup()
	}

	app.window.child_window = &ui.Window(unsafe { nil })
	app.window.update_layout()
}

fn (mut app App) set_picker_status(message string) {
	if unsafe { app.picker_status_label == 0 } {
		return
	}
	app.picker_status_label.set_text(message)
}

fn (mut app App) render_file_picker_page() {
	app.picker_selected_id = ''
	app.picker_list.clear()

	// V UI's font baseline can draw the first ListBox row through the top
	// border on this X11 setup. Reserve row 0 as visual padding so the first
	// real file/folder begins one complete item-height below the border.
	app.picker_list.add_item(picker_spacer_id, '')

	total := app.picker_entries.len
	if total == 0 {
		app.picker_list.add_item('', '(folder is empty)')
		app.picker_page_label.set_text('Page 1 / 1')
		app.set_picker_status('Folder is empty.')
		return
	}

	page_count := (total + picker_page_size - 1) / picker_page_size
	if app.picker_page < 0 {
		app.picker_page = 0
	}
	if app.picker_page >= page_count {
		app.picker_page = page_count - 1
	}

	start_at := app.picker_page * picker_page_size
	mut end_at := start_at + picker_page_size
	if end_at > total {
		end_at = total
	}

	for i in start_at .. end_at {
		entry := app.picker_entries[i]
		app.picker_list.add_item(entry.id, entry.text)
	}

	app.picker_page_label.set_text('Page ${app.picker_page + 1} / ${page_count}')
	app.set_picker_status('Showing ${start_at + 1}-${end_at} of ${total} item(s).')
}

fn sort_strings_simple(mut items []string) {
	// Keep the file picker deterministic without going through V 0.5.2's
	// builtin stable_sort path, which has crashed on this target runtime.
	mut i := 0

	for i < items.len {
		mut j := i + 1

		for j < items.len {
			if items[j] < items[i] {
				tmp := items[i]
				items[i] = items[j]
				items[j] = tmp
			}
			j++
		}

		i++
	}
}

fn (mut app App) refresh_file_picker() {
	if app.picker_dir == '' || !os.is_dir(app.picker_dir) {
		app.picker_dir = os.home_dir()
	}

	app.picker_path_label.set_text('Path: ${app.picker_dir}')
	app.picker_entries.clear()
	app.picker_selected_id = ''

	entries := os.ls(app.picker_dir) or {
		app.set_picker_status('Cannot open folder: ${err.msg()}')
		return
	}

	mut dirs := []string{}
	mut files := []string{}

	for name in entries {
		full_path := os.join_path(app.picker_dir, name)

		if os.is_dir(full_path) {
			dirs << name
		} else if os.is_file(full_path) {
			files << name
		}
	}

	sort_strings_simple(mut dirs)
	sort_strings_simple(mut files)

	for name in dirs {
		full_path := os.join_path(app.picker_dir, name)
		app.picker_entries << PickerEntry{
			id:   'dir:${full_path}'
			text: '[DIR] ${name}/'
		}
	}

	for name in files {
		full_path := os.join_path(app.picker_dir, name)
		app.picker_entries << PickerEntry{
			id:   'file:${full_path}'
			text: name
		}
	}

	app.render_file_picker_page()
}

fn remove_string(mut items []string, value string) {
	for i, item in items {
		if item == value {
			items.delete(i)
			return
		}
	}
}

fn unique_file_paths(paths []string) []string {
	mut result := []string{}

	for path in paths {
		clean := path.trim_space()
		if clean == '' || clean in result {
			continue
		}
		result << clean
	}

	return result
}

fn (mut app App) update_upload_selection_label() {
	app.upload_selection_label.set_text('Local files staged: ${app.staged_upload_files.len}')
}

fn (mut app App) stage_upload_files(paths []string, source string) bool {
	candidates := unique_file_paths(paths)

	if candidates.len == 0 {
		app.set_status('${source}: no files selected.')
		return false
	}

	for path in candidates {
		if !os.is_file(path) {
			if os.is_dir(path) {
				app.set_status('${source}: folders are not supported. Select files only.')
			} else {
				app.set_status('${source}: local file does not exist: ${path}')
			}
			return false
		}
	}

	mut added := 0
	mut preview := ''

	for path in candidates {
		preview = path
		if path !in app.staged_upload_files {
			app.staged_upload_files << path
			added++
		}
	}

	if preview == '' {
		return false
	}

	app.upload_path_box.set_text(preview)
	app.upload_path_box.cursor_pos = preview.runes().len
	app.upload_path_box.insert('')

	if app.staged_upload_files.len == 1 {
		key := app.current_prefix + os.file_name(preview)
		app.object_key_box.set_text(key)
		app.object_key_box.cursor_pos = key.runes().len
		app.object_key_box.insert('')
	} else {
		// A multi-file queue has one object key per filename. Avoid showing a
		// misleading single target key in the legacy field.
		app.object_key_box.set_text('')
	}

	app.object_details_label.set_text('Object details\nSelect an object to view details.')
	app.update_upload_selection_label()

	if added == 0 {
		app.set_status('${source}: selected file(s) were already staged.')
	} else if app.staged_upload_files.len == 1 {
		app.set_status('${source}: ${os.file_name(preview)} staged. Click Upload or Browse again to add more.')
	} else {
		app.set_status('${source}: ${app.staged_upload_files.len} files staged. Click Upload to start the sequential queue.')
	}

	return true
}

fn (mut app App) clear_staged_uploads_click(_ &ui.Button) {
	if app.upload_active {
		app.set_status('Cannot clear staged files while the upload queue is running.')
		return
	}

	app.staged_upload_files.clear()
	app.upload_path_box.set_text('')
	app.object_key_box.set_text('')
	app.update_upload_selection_label()
	app.set_status('Staged upload files cleared.')
}

fn (mut app App) prepare_upload_file(path string, source string) bool {
	return app.stage_upload_files([path], source)
}

fn (mut app App) files_dropped(_ &ui.Window, _ ui.MouseEvent) {
	if app.upload_active || app.download_active {
		app.set_status('Wait for the active transfer to finish before dropping files.')
		return
	}

	if unsafe { app.window.child_window != 0 } {
		app.set_status('Close the file picker before dropping files onto R2Box.')
		return
	}

	count := ui.get_num_dropped_files()
	if count <= 0 {
		return
	}

	mut paths := []string{cap: count}
	for i in 0 .. count {
		paths << ui.get_dropped_file_path(i)
	}

	app.stage_upload_files(paths, 'Dropped files')
}

fn (mut app App) browse_upload_click(_ &ui.Button) {
	mut start_dir := os.home_dir()
	current := app.local_upload.trim_space()

	if current != '' {
		if os.is_dir(current) {
			start_dir = current
		} else if os.is_file(current) {
			start_dir = os.dir(current)
		}
	}

	app.picker_dir = start_dir

	app.picker_path_label = ui.label(
		text: 'Path: ${app.picker_dir}'
	)

	app.picker_page = 0

	app.picker_page_label = ui.label(
		text: 'Page 1 / 1'
	)

	app.picker_status_label = ui.label(
		text: 'Loading...'
	)

	app.picker_list = ui.listbox(
		id:         'local-file-picker'
		width:      1040
		height:     382
		scrollview: false
		on_change:  app.file_picker_changed
		items:      map[string]string{}
	)

	app.window.child_window(
		title:    'Select file'
		children: [
			ui.column(
				margin:   ui.Margin{18, 18, 18, 18}
				spacing:  10
				heights:  [ui.compact, ui.compact, 382.0, ui.compact, ui.compact, ui.compact]
				children: [ui.label(
					text: 'Select a local file to upload'
				),
					ui.row(
						spacing:  8
						widths:   [ui.stretch, ui.compact, ui.compact]
						children: [app.picker_path_label,
							ui.button(
								text:     'Up'
								on_click: app.file_picker_up_click
							),
							ui.button(
								text:     'Home'
								on_click: app.file_picker_home_click
							)]
					),
					app.picker_list,
					ui.row(
						spacing:  8
						widths:   [ui.stretch, ui.compact, ui.compact]
						children: [app.picker_page_label,
							ui.button(
								text:     'Previous'
								on_click: app.file_picker_previous_click
							),
							ui.button(
								text:     'Next'
								on_click: app.file_picker_next_click
							)]
					),
					app.picker_status_label,
					ui.row(
						spacing:  8
						widths:   [ui.stretch, ui.compact, ui.compact]
						children: [ui.label(text: 'Select a folder to open it, or a file to use it.'),
							ui.button(
								text:     'Cancel'
								on_click: app.file_picker_cancel_click
							),
							ui.button(
								text:     'Open / Select'
								on_click: app.file_picker_select_click
							)]
					)]
			),
		]
	)

	// Keep the proven row hit-testing alignment. Top visual padding is provided
	// by a dedicated blank spacer row, not by shifting all item text away from
	// the ListBox hit-test grid.
	app.window.update_layout()
	app.picker_list.text_offset_y = 0
	app.refresh_file_picker()
}

fn (mut app App) file_picker_changed(list &ui.ListBox) {
	id, text := list.selected_item()

	if id == '' || id == picker_spacer_id {
		app.picker_selected_id = ''
		return
	}

	// Store the item at the moment the ListBox itself changes. This avoids
	// re-reading a selection after the Open/Select button click has generated
	// another child-window mouse event.
	app.picker_selected_id = id

	if id.starts_with('dir:') {
		app.set_picker_status('Folder selected: ${text}')
	} else if id.starts_with('file:') {
		app.set_picker_status('File selected: ${text}')
	}
}

fn (mut app App) file_picker_previous_click(_ &ui.Button) {
	if app.picker_page <= 0 {
		app.set_picker_status('Already on the first page.')
		return
	}

	app.picker_page--
	app.render_file_picker_page()
}

fn (mut app App) file_picker_next_click(_ &ui.Button) {
	page_count := if app.picker_entries.len == 0 {
		1
	} else {
		(app.picker_entries.len + picker_page_size - 1) / picker_page_size
	}

	if app.picker_page + 1 >= page_count {
		app.set_picker_status('Already on the last page.')
		return
	}

	app.picker_page++
	app.render_file_picker_page()
}

fn (mut app App) file_picker_up_click(_ &ui.Button) {
	parent := os.dir(app.picker_dir)

	if parent == app.picker_dir {
		app.set_picker_status('Already at filesystem root.')
		return
	}

	app.picker_dir = parent
	app.picker_page = 0
	app.refresh_file_picker()
}

fn (mut app App) file_picker_home_click(_ &ui.Button) {
	app.picker_dir = os.home_dir()
	app.picker_page = 0
	app.refresh_file_picker()
}

fn (mut app App) file_picker_cancel_click(_ &ui.Button) {
	app.close_file_picker()
	app.set_status('File selection cancelled.')
}

fn (mut app App) file_picker_select_click(_ &ui.Button) {
	id := app.picker_selected_id

	if id == '' || id == picker_spacer_id {
		app.set_picker_status('Select a file or folder first.')
		return
	}

	if id.starts_with('dir:') {
		path := id[4..]
		if !os.is_dir(path) {
			app.set_picker_status('Folder no longer exists.')
			return
		}

		app.picker_dir = path
		app.picker_page = 0
		app.refresh_file_picker()
		return
	}

	if id.starts_with('file:') {
		path := id[5..]

		if !app.prepare_upload_file(path, 'Selected file') {
			app.set_picker_status('File could not be selected.')
			return
		}

		app.picker_selected_id = ''
		app.close_file_picker()
	}
}

fn (app &App) new_s3_client() s3.Client {
	return s3.new_client(s3.Credentials{
		endpoint:          app.endpoint.trim_space()
		access_key_id:     app.access_key.trim_space()
		secret_access_key: app.secret_key
		region:            'auto'
		bucket:            app.bucket.trim_space()
	})
}

fn (mut app App) validate_connection() bool {
	if app.endpoint.trim_space() == '' {
		app.set_status('Error: endpoint is empty.')
		return false
	}
	if app.access_key.trim_space() == '' {
		app.set_status('Error: Access Key ID is empty.')
		return false
	}
	if app.secret_key == '' {
		app.set_status('Error: Secret Access Key is empty.')
		return false
	}
	if app.bucket.trim_space() == '' {
		app.set_status('Error: bucket name is empty.')
		return false
	}
	return true
}

fn (mut app App) set_status(message string) {
	app.status = message
	app.status_label.set_text(message)
}

fn user_download_dir() string {
	home := os.home_dir()
	config_dir := os.config_dir() or { os.join_path(home, '.config') }
	user_dirs_file := os.join_path(config_dir, 'user-dirs.dirs')

	if os.is_file(user_dirs_file) {
		content := os.read_file(user_dirs_file) or { '' }

		for raw_line in content.split_into_lines() {
			line := raw_line.trim_space()

			if !line.starts_with('XDG_DOWNLOAD_DIR=') {
				continue
			}

			mut value := line.all_after('=').trim_space()

			if value.starts_with('"') && value.ends_with('"') && value.len >= 2 {
				value = value[1..value.len - 1]
			}

			// user-dirs.dirs commonly stores paths as "$HOME/Downloads".
			dollar_home := '$' + 'HOME'
			value = value.replace(dollar_home, home)

			if os.is_dir(value) {
				return value
			}
		}
	}

	fallback := os.join_path(home, 'Downloads')
	if os.is_dir(fallback) {
		return fallback
	}

	// Last-resort fallback: never invent another user's absolute path.
	return home
}

fn default_download_path(key string) string {
	mut name := os.file_name(key)
	if name == '' {
		name = 'r2box-download'
	}
	return os.join_path(user_download_dir(), name)
}

fn (mut app App) set_download_path_for_key(key string) {
	path := default_download_path(key)

	app.download_to_box.set_text(path)
	app.download_to_box.cursor_pos = path.runes().len
	app.download_to_box.insert('')
}

fn browser_path(prefix string) string {
	if prefix == '' {
		return '/'
	}
	return '/${prefix}'
}

fn relative_browser_name(key string, prefix string) string {
	if prefix != '' && key.starts_with(prefix) {
		return key[prefix.len..]
	}
	return key
}

fn (mut app App) update_path_label() {
	app.path_label.set_text('Path: ${browser_path(app.current_prefix)}')
}

fn (mut app App) update_page_label() {
	app.page_label.set_text('Page ${app.page_index + 1}')
}

fn (mut app App) reset_pagination() {
	app.page_index = 0
	app.page_tokens = ['']
	app.next_page_token = ''
	app.update_page_label()
}

fn (app &App) current_page_token() string {
	if app.page_index >= 0 && app.page_index < app.page_tokens.len {
		return app.page_tokens[app.page_index]
	}
	return ''
}

fn (mut app App) previous_page_click(_ &ui.Button) {
	if app.page_index <= 0 {
		app.set_status('Already on the first page.')
		return
	}

	app.page_index--
	app.object_key_box.set_text('')
	app.update_page_label()
	app.refresh_objects()
}

fn (mut app App) next_page_click(_ &ui.Button) {
	if app.next_page_token == '' {
		app.set_status('No next page.')
		return
	}

	next_index := app.page_index + 1

	if next_index < app.page_tokens.len {
		app.page_tokens[next_index] = app.next_page_token
	} else {
		app.page_tokens << app.next_page_token
	}

	app.page_index = next_index
	app.object_key_box.set_text('')
	app.update_page_label()
	app.refresh_objects()
}

fn (mut app App) render_object_list() {
	app.objects_box.clear()

	needle := app.object_filter.trim_space().to_lower()
	mut shown := 0

	for entry in app.all_objects {
		if needle != '' && !entry.key.to_lower().contains(needle)
			&& !entry.display.to_lower().contains(needle) {
			continue
		}

		id := if entry.is_dir { 'dir:${entry.key}' } else { 'obj:${entry.key}' }
		app.objects_box.add_item(id, entry.display)
		shown++
	}

	if app.all_objects.len == 0 {
		empty_text := if app.current_prefix == '' {
			'(bucket is empty)'
		} else {
			'(folder is empty)'
		}
		app.objects_box.add_item('', empty_text)
		return
	}

	if shown == 0 {
		app.objects_box.add_item('', '(no matching items)')
	}
}

fn (mut app App) apply_filter() {
	app.render_object_list()

	// Filtering clears the visible selection. Clear Object Key as well so an
	// object hidden by the filter cannot accidentally be deleted/downloaded.
	app.object_key_box.set_text('')

	needle := app.object_filter.trim_space()
	if needle == '' {
		app.set_status('Page ${app.page_index + 1}: showing all ${app.all_objects.len} item(s) in ${browser_path(app.current_prefix)}.')
		return
	}

	mut matches := 0
	lower_needle := needle.to_lower()
	for entry in app.all_objects {
		if entry.key.to_lower().contains(lower_needle)
			|| entry.display.to_lower().contains(lower_needle) {
			matches++
		}
	}

	app.set_status('Page ${app.page_index + 1} filter "${needle}": ${matches} of ${app.all_objects.len} item(s) in ${browser_path(app.current_prefix)}.')
}

fn (mut app App) filter_enter(_ &ui.TextBox) {
	app.apply_filter()
}

fn (mut app App) filter_click(_ &ui.Button) {
	app.apply_filter()
}

fn (mut app App) clear_filter_click(_ &ui.Button) {
	app.filter_box.set_text('')
	app.render_object_list()
	app.object_key_box.set_text('')
	app.set_status('Page ${app.page_index + 1}: showing all ${app.all_objects.len} item(s) in ${browser_path(app.current_prefix)}.')
}

fn (mut app App) navigate_to(prefix string) {
	app.current_prefix = prefix
	app.filter_box.set_text('')
	app.object_key_box.set_text('')
	app.object_details_label.set_text('Object details\nSelect an object to view details.')
	app.reset_pagination()
	app.update_path_label()
	app.refresh_objects()
}

fn (mut app App) root_click(_ &ui.Button) {
	if app.current_prefix == '' {
		app.set_status('Already at bucket root.')
		return
	}
	app.navigate_to('')
}

fn (mut app App) up_click(_ &ui.Button) {
	if app.current_prefix == '' {
		app.set_status('Already at bucket root.')
		return
	}

	mut path := app.current_prefix
	if path.ends_with('/') {
		path = path[..path.len - 1]
	}

	parts := path.split('/')
	if parts.len <= 1 {
		app.navigate_to('')
		return
	}

	parent := parts[..parts.len - 1].join('/') + '/'
	app.navigate_to(parent)
}

fn (mut app App) object_selected(list &ui.ListBox) {
	id, _ := list.selected_item()

	if id == '' {
		return
	}

	if id.starts_with('dir:') {
		app.object_details_label.set_text('Object details\nSelect an object to view details.')
		app.navigate_to(id[4..])
		return
	}

	if id.starts_with('obj:') {
		key := id[4..]
		app.object_key_box.set_text(key)
		app.object_key_box.cursor_pos = key.runes().len
		app.object_key_box.insert('')

		app.set_download_path_for_key(key)
		app.show_object_details_loading(key)
		app.set_status('Selected: ${key}')

		job := ObjectDetailsJob{
			endpoint:   app.endpoint.trim_space()
			access_key: app.access_key.trim_space()
			secret_key: app.secret_key
			bucket:     app.bucket.trim_space()
			key:        key
		}

		spawn object_details_worker(job, app.object_details_events)
	}
}

fn (mut app App) refresh_click(_ &ui.Button) {
	app.refresh_objects()
}

fn (mut app App) refresh_objects() {
	if !app.validate_connection() {
		return
	}

	app.update_path_label()
	app.update_page_label()
	app.set_status('Loading page ${app.page_index + 1} of ${browser_path(app.current_prefix)}...')
	client := app.new_s3_client()

	result := client.list(s3.ListOptions{
		prefix:             app.current_prefix
		continuation_token: app.current_page_token()
		delimiter:          '/'
		max_keys:           1000
	}) or {
		app.set_status('R2 error: ${err.msg()}')
		return
	}

	app.next_page_token = if result.is_truncated {
		result.next_continuation_token
	} else {
		''
	}

	app.all_objects.clear()

	// S3 common prefixes are directory-like entries produced by delimiter '/'.
	for common in result.common_prefixes {
		name := relative_browser_name(common.prefix, app.current_prefix)
		app.all_objects << ObjectEntry{
			key:     common.prefix
			display: '[DIR] ${name}'
			is_dir:  true
		}
	}

	for object in result.objects {
		// Folder marker objects such as "photos/" are not useful as separate
		// files while browsing inside that same prefix.
		if app.current_prefix != '' && object.key == app.current_prefix {
			continue
		}

		mut name := relative_browser_name(object.key, app.current_prefix)
		if name == '' {
			name = object.key
		}

		app.all_objects << ObjectEntry{
			key:     object.key
			display: '${name}    ${object.size} bytes    ${object.last_modified}'
			is_dir:  false
		}
	}

	app.render_object_list()

	if result.is_truncated {
		app.set_status('Page ${app.page_index + 1}: ${app.all_objects.len} item(s) in ${browser_path(app.current_prefix)}. Next page available.')
	} else {
		app.set_status('Page ${app.page_index + 1}: ${app.all_objects.len} item(s) in ${browser_path(app.current_prefix)}.')
	}
}

fn object_details_worker(job ObjectDetailsJob, events chan ObjectDetailsEvent) {
	client := s3.new_client(s3.Credentials{
		endpoint:          job.endpoint
		access_key_id:     job.access_key
		secret_access_key: job.secret_key
		region:            'auto'
		bucket:            job.bucket
	})

	meta := client.stat(job.key) or {
		events <- ObjectDetailsEvent{
			key:           job.key
			error_message: err.msg()
		}
		return
	}

	events <- ObjectDetailsEvent{
		key:           job.key
		size:          meta.size
		last_modified: meta.last_modified
		etag:          meta.etag
		content_type:  meta.content_type
	}
}

fn upload_worker(job UploadJob, events chan UploadEvent, cancel chan bool) {
	client := s3.new_client(s3.Credentials{
		endpoint:          job.endpoint
		access_key_id:     job.access_key
		secret_access_key: job.secret_key
		region:            'auto'
		bucket:            job.bucket
	})

	if cancel_requested(cancel) {
		events <- UploadEvent{
			kind:    .cancelled
			key:     job.key
			total:   job.total
			message: 'Upload cancelled before transfer started.'
		}
		return
	}

	events <- UploadEvent{
		kind:     .progress
		key:      job.key
		uploaded: 0
		total:    job.total
	}

	opts := s3.PutOptions{
		content_type: 'application/octet-stream'
	}

	// S3 multipart parts must be at least 5 MiB except for the final part.
	// Small files can use a normal PUT and simply jump from 0% to 100%.
	if job.total <= upload_chunk_size {
		data := os.read_bytes(job.local_path) or {
			events <- UploadEvent{
				kind:    .failed
				key:     job.key
				total:   job.total
				message: 'Cannot read upload file: ${err.msg()}'
			}
			return
		}

		if cancel_requested(cancel) {
			events <- UploadEvent{
				kind:    .cancelled
				key:     job.key
				total:   job.total
				message: 'Upload cancelled before the single PUT request started.'
			}
			return
		}

		client.put(job.key, data, opts) or {
			events <- UploadEvent{
				kind:    .failed
				key:     job.key
				total:   job.total
				message: 'Upload failed: ${err.msg()}'
			}
			return
		}

		events <- UploadEvent{
			kind:     .completed
			key:      job.key
			uploaded: job.total
			total:    job.total
		}
		return
	}

	mut file := os.open(job.local_path) or {
		events <- UploadEvent{
			kind:    .failed
			key:     job.key
			total:   job.total
			message: 'Cannot open upload file: ${err.msg()}'
		}
		return
	}
	defer {
		file.close()
	}

	mut uploader := client.start_multipart(job.key, opts) or {
		events <- UploadEvent{
			kind:    .failed
			key:     job.key
			total:   job.total
			message: 'Cannot start multipart upload: ${err.msg()}'
		}
		return
	}

	if cancel_requested(cancel) {
		uploader.abort() or {}
		events <- UploadEvent{
			kind:    .cancelled
			key:     job.key
			total:   job.total
			message: 'Multipart upload cancelled before the first part.'
		}
		return
	}

	mut offset := i64(0)

	for offset < job.total {
		if cancel_requested(cancel) {
			uploader.abort() or {}
			events <- UploadEvent{
				kind:     .cancelled
				key:      job.key
				uploaded: offset
				total:    job.total
				message:  'Multipart upload cancelled. In-flight multipart data was aborted.'
			}
			return
		}

		want := if offset + upload_chunk_size > job.total {
			int(job.total - offset)
		} else {
			int(upload_chunk_size)
		}

		mut buffer := []u8{len: want}
		n := file.read_bytes_into(u64(offset), mut buffer) or {
			uploader.abort() or {}
			events <- UploadEvent{
				kind:     .failed
				key:      job.key
				uploaded: offset
				total:    job.total
				message:  'Cannot read local upload at byte ${offset}: ${err.msg()}'
			}
			return
		}

		if n <= 0 {
			uploader.abort() or {}
			events <- UploadEvent{
				kind:     .failed
				key:      job.key
				uploaded: offset
				total:    job.total
				message:  'Unexpected EOF while reading local upload at byte ${offset}.'
			}
			return
		}

		if cancel_requested(cancel) {
			uploader.abort() or {}
			events <- UploadEvent{
				kind:     .cancelled
				key:      job.key
				uploaded: offset
				total:    job.total
				message:  'Multipart upload cancelled before the next part was sent.'
			}
			return
		}

		uploader.upload(buffer[..n]) or {
			uploader.abort() or {}
			events <- UploadEvent{
				kind:     .failed
				key:      job.key
				uploaded: offset
				total:    job.total
				message:  'Multipart upload failed at byte ${offset}: ${err.msg()}'
			}
			return
		}

		if cancel_requested(cancel) {
			uploader.abort() or {}
			events <- UploadEvent{
				kind:     .cancelled
				key:      job.key
				uploaded: offset
				total:    job.total
				message:  'Multipart upload cancelled after the current part request completed; multipart upload was aborted.'
			}
			return
		}

		offset += i64(n)

		events <- UploadEvent{
			kind:     .progress
			key:      job.key
			uploaded: offset
			total:    job.total
		}
	}

	if cancel_requested(cancel) {
		uploader.abort() or {}
		events <- UploadEvent{
			kind:     .cancelled
			key:      job.key
			uploaded: offset
			total:    job.total
			message:  'Multipart upload cancelled before finalization.'
		}
		return
	}

	uploader.complete() or {
		uploader.abort() or {}
		events <- UploadEvent{
			kind:     .failed
			key:      job.key
			uploaded: offset
			total:    job.total
			message:  'Cannot finalize multipart upload: ${err.msg()}'
		}
		return
	}

	events <- UploadEvent{
		kind:     .completed
		key:      job.key
		uploaded: job.total
		total:    job.total
	}
}

fn (mut app App) upload_click(_ &ui.Button) {
	if app.upload_active {
		app.set_status('An upload queue is already running.')
		return
	}

	if app.download_active {
		app.set_status('Wait for the current download to finish before uploading.')
		return
	}

	if !app.validate_connection() {
		return
	}

	mut paths := []string{}

	if app.staged_upload_files.len > 0 {
		paths = app.staged_upload_files.clone()
	} else {
		local_path := app.local_upload.trim_space()
		if local_path == '' {
			app.set_status('Error: no local files are staged.')
			return
		}
		paths << local_path
	}

	paths = unique_file_paths(paths)

	if paths.len == 0 {
		app.set_status('Error: no local files are staged.')
		return
	}

	app.upload_queue.clear()
	app.upload_failed_jobs.clear()
	app.upload_cancel_requested = false
	app.upload_queue_index = 0
	app.upload_completed = 0
	app.upload_failed = 0

	mut target_keys := []string{}

	for path in paths {
		if !os.is_file(path) {
			app.set_status('Upload queue stopped: local file does not exist: ${path}')
			app.upload_queue.clear()
			return
		}

		stat_local := os.stat(path) or {
			app.set_status('Cannot read local file metadata: ${err.msg()}')
			app.upload_queue.clear()
			return
		}

		mut key := ''

		if paths.len == 1 {
			// Preserve the existing custom Object Key workflow for one file.
			key = app.object_key.trim_space()
			if key == '' {
				key = app.current_prefix + os.file_name(path)
			}
		} else {
			// Multi-file queue maps every file to the active prefix + basename.
			key = app.current_prefix + os.file_name(path)
		}

		if key in target_keys {
			app.set_status('Upload queue stopped: multiple local files resolve to the same object key: ${key}')
			app.upload_queue.clear()
			return
		}
		target_keys << key

		app.upload_queue << UploadJob{
			endpoint:   app.endpoint.trim_space()
			access_key: app.access_key.trim_space()
			secret_key: app.secret_key
			bucket:     app.bucket.trim_space()
			key:        key
			local_path: path
			total:      i64(stat_local.size)
		}
	}

	if app.upload_queue.len == 0 {
		app.set_status('Error: upload queue is empty.')
		return
	}

	// Show the first target in the legacy single-object field as a useful
	// preview. Remaining queue items use current prefix + their own filename.
	first_job := app.upload_queue[0]
	app.upload_path_box.set_text(first_job.local_path)
	app.upload_path_box.cursor_pos = first_job.local_path.runes().len
	app.upload_path_box.insert('')

	app.object_key_box.set_text(first_job.key)
	app.object_key_box.cursor_pos = first_job.key.runes().len
	app.object_key_box.insert('')

	app.upload_active = true
	app.upload_progress.val = 0
	app.update_upload_queue_label()

	if app.upload_queue.len == 1 {
		app.set_status('Starting upload: ${first_job.key}')
	} else {
		app.set_status('Starting sequential upload queue: ${app.upload_queue.len} files.')
	}

	app.start_current_upload_job()
}

fn download_worker(job DownloadJob, events chan DownloadEvent, cancel chan bool) {
	client := s3.new_client(s3.Credentials{
		endpoint:          job.endpoint
		access_key_id:     job.access_key
		secret_access_key: job.secret_key
		region:            'auto'
		bucket:            job.bucket
	})

	if cancel_requested(cancel) {
		events <- DownloadEvent{
			kind:        .cancelled
			key:         job.key
			destination: job.destination
			message:     'Download cancelled before transfer started.'
		}
		return
	}

	meta := client.stat(job.key) or {
		events <- DownloadEvent{
			kind:        .failed
			key:         job.key
			destination: job.destination
			message:     'Cannot read object metadata: ${err.msg()}'
		}
		return
	}

	events <- DownloadEvent{
		kind:        .progress
		key:         job.key
		destination: job.destination
		downloaded:  0
		total:       meta.size
	}

	if cancel_requested(cancel) {
		events <- DownloadEvent{
			kind:        .cancelled
			key:         job.key
			destination: job.destination
			total:       meta.size
			message:     'Download cancelled before the partial file was created.'
		}
		return
	}

	mut file := os.create(job.partial_path) or {
		events <- DownloadEvent{
			kind:        .failed
			key:         job.key
			destination: job.destination
			total:       meta.size
			message:     'Cannot create partial file: ${err.msg()}'
		}
		return
	}

	if meta.size == 0 {
		file.close()

		if cancel_requested(cancel) {
			events <- DownloadEvent{
				kind:        .cancelled
				key:         job.key
				destination: job.destination
				total:       0
				message:     'Download cancelled before finalizing the empty object.'
			}
			return
		}

		if os.exists(job.destination) {
			events <- DownloadEvent{
				kind:        .failed
				key:         job.key
				destination: job.destination
				message:     'Download stopped: destination appeared while downloading.'
			}
			return
		}

		os.mv(job.partial_path, job.destination) or {
			events <- DownloadEvent{
				kind:        .failed
				key:         job.key
				destination: job.destination
				message:     'Cannot finalize empty download: ${err.msg()}'
			}
			return
		}

		events <- DownloadEvent{
			kind:        .completed
			key:         job.key
			destination: job.destination
			total:       0
		}
		return
	}

	mut offset := i64(0)

	for offset < meta.size {
		if cancel_requested(cancel) {
			file.close()
			events <- DownloadEvent{
				kind:        .cancelled
				key:         job.key
				destination: job.destination
				downloaded:  offset
				total:       meta.size
				message:     'Download cancelled. Partial file kept: ${job.partial_path}.'
			}
			return
		}

		end_offset := if offset + download_chunk_size > meta.size {
			meta.size - 1
		} else {
			offset + download_chunk_size - 1
		}

		data := client.get(job.key, s3.GetOptions{
			range: 'bytes=${offset}-${end_offset}'
		}) or {
			file.close()
			events <- DownloadEvent{
				kind:        .failed
				key:         job.key
				destination: job.destination
				downloaded:  offset
				total:       meta.size
				message:     'Download failed at byte ${offset}. Partial file kept: ${job.partial_path}. ${err.msg()}'
			}
			return
		}

		if cancel_requested(cancel) {
			file.close()
			events <- DownloadEvent{
				kind:        .cancelled
				key:         job.key
				destination: job.destination
				downloaded:  offset
				total:       meta.size
				message:     'Download cancelled after the current network request. Partial file kept: ${job.partial_path}.'
			}
			return
		}

		expected := int(end_offset - offset + 1)
		if data.len != expected {
			file.close()
			events <- DownloadEvent{
				kind:        .failed
				key:         job.key
				destination: job.destination
				downloaded:  offset
				total:       meta.size
				message:     'Download failed: expected ${expected} bytes, received ${data.len}. Partial file kept.'
			}
			return
		}

		write_all(mut file, data) or {
			file.close()
			events <- DownloadEvent{
				kind:        .failed
				key:         job.key
				destination: job.destination
				downloaded:  offset
				total:       meta.size
				message:     'Cannot save download at byte ${offset}: ${err.msg()}. Partial file kept.'
			}
			return
		}

		offset = end_offset + 1

		if cancel_requested(cancel) {
			file.close()
			events <- DownloadEvent{
				kind:        .cancelled
				key:         job.key
				destination: job.destination
				downloaded:  offset
				total:       meta.size
				message:     'Download cancelled. Partial file kept: ${job.partial_path}.'
			}
			return
		}

		events <- DownloadEvent{
			kind:        .progress
			key:         job.key
			destination: job.destination
			downloaded:  offset
			total:       meta.size
		}
	}

	file.close()

	if cancel_requested(cancel) {
		events <- DownloadEvent{
			kind:        .cancelled
			key:         job.key
			destination: job.destination
			downloaded:  meta.size
			total:       meta.size
			message:     'Download cancelled before final rename. Partial file kept: ${job.partial_path}.'
		}
		return
	}

	// Preserve Stage 3's no-overwrite rule even if another process creates
	// the final destination while this background transfer is running.
	if os.exists(job.destination) {
		events <- DownloadEvent{
			kind:        .failed
			key:         job.key
			destination: job.destination
			downloaded:  meta.size
			total:       meta.size
			message:     'Download finished, but destination now exists. Partial file kept: ${job.partial_path}.'
		}
		return
	}

	os.mv(job.partial_path, job.destination) or {
		events <- DownloadEvent{
			kind:        .failed
			key:         job.key
			destination: job.destination
			downloaded:  meta.size
			total:       meta.size
			message:     'Download finished but cannot rename .part file: ${err.msg()}'
		}
		return
	}

	events <- DownloadEvent{
		kind:        .completed
		key:         job.key
		destination: job.destination
		downloaded:  meta.size
		total:       meta.size
	}
}

fn write_all(mut file os.File, data []u8) ! {
	mut written := 0

	for written < data.len {
		n := file.write(data[written..])!
		if n <= 0 {
			return error('short write while saving download')
		}
		written += n
	}
}

fn (mut app App) download_click(_ &ui.Button) {
	if app.download_active {
		app.set_status('A download queue is already running.')
		return
	}

	if app.upload_active {
		app.set_status('Wait for the current upload queue to finish before downloading.')
		return
	}

	if !app.validate_connection() {
		return
	}

	// Preserve the old one-click workflow: when nothing has been staged,
	// Download automatically stages the currently selected object.
	if app.staged_downloads.len == 0 {
		if !app.stage_download(app.object_key, app.download_to) {
			return
		}
	}

	app.download_queue.clear()
	app.download_failed_jobs.clear()
	app.download_cancel_requested = false
	app.download_queue_index = 0
	app.download_completed = 0
	app.download_failed = 0

	for item in app.staged_downloads {
		app.download_queue << DownloadJob{
			endpoint:     app.endpoint.trim_space()
			access_key:   app.access_key.trim_space()
			secret_key:   app.secret_key
			bucket:       app.bucket.trim_space()
			key:          item.key
			destination:  item.destination
			partial_path: '${item.destination}.part'
		}
	}

	if app.download_queue.len == 0 {
		app.set_status('Error: download queue is empty.')
		return
	}

	app.download_active = true
	app.download_progress.val = 0
	app.update_download_queue_label()

	if app.download_queue.len == 1 {
		app.set_status('Starting download: ${app.download_queue[0].key}')
	} else {
		app.set_status('Starting sequential download queue: ${app.download_queue.len} objects.')
	}

	app.start_current_download_job()
}

fn (mut app App) delete_click(_ &ui.Button) {
	if !app.validate_connection() {
		return
	}

	key := app.object_key.trim_space()
	if key == '' {
		app.set_status('Error: object key is empty.')
		return
	}
	if app.delete_confirm.trim_space() != 'DELETE' {
		app.set_status('Type DELETE before deleting an object.')
		return
	}

	app.set_status('Deleting ${key}...')
	client := app.new_s3_client()

	client.delete(key) or {
		app.set_status('Delete failed: ${err.msg()}')
		return
	}

	app.delete_box.set_text('')
	app.object_key_box.set_text('')
	app.object_details_label.set_text('Object details\nSelect an object to view details.')
	app.reset_pagination()
	app.refresh_objects()
	app.set_status('Deleted: ${key}')
}
