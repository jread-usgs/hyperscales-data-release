
extract_model_ids <- function(job_list_rds, results_dir, dummy){
  warning('this is a temporary function and should be replaced with an inventory of **modeled** lakes')
  files_here <- dir(results_dir)
  job_list <- readRDS(job_list_rds)
  # these are export files...
  job_files <- unlist(sapply(1:length(job_list), function(x) c(basename(job_list[[x]]$export_file))) %>% c())
  
  tibble(files = files_here[files_here %in% job_files]) %>% 
    extract(files, c('type','site_id'), "(pb0|transfer|pball)_(.*)_temperatures.feather") %>% pull(site_id)
  
}

extract_from_rds <- function(file){
  readRDS(file)$site_id
}

extract_model_from_table <- function(job_table_ind){
  tibble(files = names(yaml::yaml.load_file(job_table_ind))) %>% 
    extract(files, c('type','site_id'), "(pb0|transfer|pball)_(.*)_temperatures.feather") %>% pull(site_id)
  
}


create_metadata_file <- function(fileout, sites, table, lakes_sf, lat_lon_fl, meteo_fl, gnis_names_fl){
  sdf <- sf::st_transform(lakes_sf, 2811) %>% 
    mutate(perim = lwgeom::st_perimeter_2d(Shape), area = sf::st_area(Shape), circle_perim = 2*pi*sqrt(area/pi), SDF = perim/circle_perim) %>% 
    sf::st_drop_geometry() %>% select(site_id, SDF) 

  sites %>% inner_join((readRDS(lat_lon_fl)), by = 'site_id') %>% 
    inner_join(sdf, by = 'site_id') %>% 
    rename(centroid_lon = longitude, centroid_lat = latitude) %>% 
    inner_join(table, by = 'site_id') %>% 
    inner_join(readRDS(meteo_fl), by = 'site_id') %>% 
    inner_join((readRDS(gnis_names_fl)), by = 'site_id') %>% rename(lake_name = GNIS_Name, meteo_filename = meteo_fl) %>% 
    mutate(meteo_filename = stringr::str_replace(meteo_filename, '367700', replacement = '359420')) %>% 
    write_csv(fileout)
  
}
bundle_nml_files <- function(json_filename, lake_ids, nml_ind){
  
  
  prep_proj_dir <- paste(str_split(nml_ind, '/')[[1]][1:2], collapse = '/')
  nml_files <- file.path(prep_proj_dir, names(yaml.load_file(nml_ind)))
  file_bases <- tibble(file = basename(nml_files)) %>% 
    mutate(filebase = str_remove(file, 'pball_|transfer_')) %>% pull(filebase)
  out_list <- vector("list", length = length(lake_ids)) %>% setNames(lake_ids)
  
  for (id in names(out_list)){
    this_nml_file <- nml_files[file_bases == paste0(id, '.nml')]
    if (!file.exists(this_nml_file)){
      stop(this_nml_file, " doesn't exist")
    }
    nml <- read_nml(nml_file = this_nml_file) %>% unclass()
    out_list[[id]] <- nml
  }
  
  RJSONIO::toJSON(out_list, pretty = TRUE) %>% write(json_filename)
}

zip_nml_files <- function(zipfile, lake_ids, nml_ind){
  
  cd <- getwd()
  on.exit(setwd(cd))
  zippath <- file.path(getwd(), zipfile)
  
  prep_proj_dir <- paste(str_split(nml_ind, '/')[[1]][1:2], collapse = '/')
  
  nml_files <- file.path(prep_proj_dir, names(yaml.load_file(nml_ind)))
  
  setwd(unique(dirname(nml_files))[1])
  if (file.exists(zippath)){
    unlink(zippath) #seems it was adding to the zip as opposed to wiping and starting fresh...
  }
  zip(zippath, files = basename(nml_files))
  setwd(cd)
}

group_meteo_fls <- function(meteo_dir, groups){
  
  # turn files into point locations
  # check group match with assign_group_id(points, polygons)
  # return data.frame with id and filename
  message('need to modify this to work with the local_drivers.ind file')
  meteo_fls <- tibble(files = dir(meteo_dir)) %>% 
    filter(stringr::str_detect(files, "[0-9n]\\].csv")) %>% 
    mutate(x = stringr::str_extract(files, 'x\\[[0-9]+\\]') %>% str_remove('x\\[') %>% str_remove('\\]') %>% as.numeric(),
           y = stringr::str_extract(files, 'y\\[[0-9]+\\]') %>% str_remove('y\\[') %>% str_remove('\\]') %>% as.numeric()) %>% 
    left_join(suppressWarnings(st_centroid(create_ldas_grid()))) %>% rename(geometry = ldas_grid_sfc) %>% select(-x, -y) %>% 
    st_sf()
  
  grouped_df <- st_intersects(x = meteo_fls, y = groups) %>% as.data.frame() %>% rename(group_idx = col.id)
  
  meteo_fls %>% mutate(row.id = row_number()) %>% 
    inner_join(grouped_df) %>% mutate(group_id = groups$group_id[group_idx], meteo_filepath = file.path(meteo_dir, files)) %>% 
    select(meteo_filepath, group_id) %>% st_drop_geometry()
  
}

zip_meteo_groups <- function(outfile, grouped_meteo_fls){

  cd <- getwd()
  on.exit(setwd(cd))
  
  groups <- unique(grouped_meteo_fls$group_id)
  data_files <- c()
  for (group in groups){
    zipfile <- paste0('tmp/inputs_', group, '.zip')
    these_files <- grouped_meteo_fls %>% filter(group_id == !!group) %>% pull(meteo_filepath)
    
    zippath <- file.path(getwd(), zipfile)
    
    if (file.exists(zippath)){
      unlink(zippath) #seems it was adding to the zip as opposed to wiping and starting fresh...
    }
    
    meteo_dir <- dirname(these_files) %>% unique()
    
    setwd(meteo_dir)
    zip(zippath, files = basename(these_files))
    setwd(cd)
    data_files <- c(data_files, zipfile)
  }
  scipiper::sc_indicate(outfile, data_file = data_files)
}

build_predict_df <- function(site_id_list, model_dir, dummy){
  
  selected_sites <- purrr::map(names(site_id_list), function(x){
    tibble(site_id = site_id_list[[x]], prefix = x)
  }) %>% purrr::reduce(bind_rows)
  
  tibble(source_file = dir(model_dir)) %>% 
    filter(str_detect(source_file, '_temperatures.feather$')) %>% 
    extract(source_file, c('prefix','site_id','suffix'), "(pb0|pball|pgdl)_(.*)_(temperatures.feather)", remove = FALSE) %>% 
    inner_join(selected_sites) %>% select(-suffix, -prefix) %>% 
    mutate(out_file = paste0(tools::file_path_sans_ext(source_file), '.csv'), 
           source_filepath = file.path(model_dir, source_file)) %>% select(-source_file)
    
}
  
zip_prediction_groups <- function(outfile, predictions_df, site_groups){
  
  model_feathers <- inner_join(predictions_df, site_groups, by = 'site_id') %>% 
    select(-site_id)
  
  
  cd <- getwd()
  on.exit(setwd(cd))
  
  groups <- rev(sort(unique(model_feathers$group_id)))
  data_files <- c()
  for (group in groups){
    zipfile <- paste0('tmp/predictions_', group, '.zip')
    these_files <- model_feathers %>% filter(group_id == !!group)
    
    zippath <- file.path(getwd(), zipfile)
    
    if (file.exists(zippath)){
      unlink(zippath) #seems it was adding to the zip as opposed to wiping and starting fresh...
    }
    
    for (i in 1:nrow(these_files)){
      fileout <- file.path(tempdir(), these_files$out_file[i])
      feather::read_feather(these_files$source_filepath[i]) %>%
        dplyr::select(-ice) %>%
        # was oddly getting Error in (function (dt, year, month, yday, mday, wday, hour, minute, second,  : 
        #CCTZ: Invalid timezone of the input vector: "Etc/GMT+7" for at least one file
        dplyr::mutate(date = as.character(DateTime)) %>% 
        select(-DateTime, date, everything()) %>% 
        readr::write_csv(path = fileout)
      
      fileout
    }
    
    setwd(tempdir())
    
    zip(zippath, files = these_files$out_file)
    unlink(these_files$out_file)
    setwd(cd)
    data_files <- c(data_files, zipfile)
  }
  scipiper::sc_indicate(outfile, data_file = data_files)
}

#' function is nearly identical to `zip_prediction_groups`. We should modify and merge...but right now that build takes a long time
#' and I am avoiding merging these two functions for that reason. 
#' 
#' How to modify and merge: 
#' 1) could make `build_predict_df` more generic and allow us to specify the `out_file` suffix
#' 2) could add an argument to a generic function `zip_file_groups` that tells us what to do (will need to export differently too)
zip_ice_flags_groups <- function(outfile, file_info_df, site_groups){
  
  model_feathers <- inner_join(file_info_df, site_groups, by = 'site_id') %>% 
    mutate(out_file = str_remove(
      paste0(tools::file_path_sans_ext(out_file), '_ice_flag.csv'), '_temperatures')
    ) %>% 
    select(-site_id)
  
  
  cd <- getwd()
  on.exit(setwd(cd))
  
  groups <- rev(sort(unique(model_feathers$group_id)))
  data_files <- c()
  for (group in groups){
    zipfile <- paste0('tmp/ice_flags_', group, '.zip')
    these_files <- model_feathers %>% filter(group_id == !!group)
    
    zippath <- file.path(getwd(), zipfile)
    if (file.exists(zippath)){
      unlink(zippath) #seems it was adding to the zip as opposed to wiping and starting fresh...
    }
    for (i in 1:nrow(these_files)){
      fileout <- file.path(tempdir(), these_files$out_file[i])
      feather::read_feather(these_files$source_filepath[i]) %>%
        dplyr::select(date = DateTime, ice) %>% # <- note this line also differs from the temperature export
        # was oddly getting Error in (function (dt, year, month, yday, mday, wday, hour, minute, second,  : 
        #CCTZ: Invalid timezone of the input vector: "Etc/GMT+7" for at least one file
        dplyr::mutate(date = as.character(date)) %>% 
        write_csv(path = fileout)
      fileout
    }
    
    setwd(tempdir())
    
    zip(zippath, files = these_files$out_file)
    unlink(these_files$out_file)
    setwd(cd)
    data_files <- c(data_files, zipfile)
  }
  scipiper::sc_indicate(outfile, data_file = data_files)
}

zip_temp_obs <- function(outfile, temp_feather, site_ids, time_range){
  
  remove_sources <- c('7a_temp_coop_munge/tmp/upper_red_bottom_temp_DO_4metersdeep.rds',
                      '7a_temp_coop_munge/tmp/upper_red_surface_DO_temps.rds',
                      '7a_temp_coop_munge/tmp/lower_red_bottom_temp_DO_9metersdeep_2017.rds',
                      '7a_temp_coop_munge/tmp/lower_red_bottom2010.rds',
                      '7a_temp_coop_munge/tmp/lower_red_bottom2013.rds',
                      '7a_temp_coop_munge/tmp/lower_red_bottom2014.rds',
                      '7a_temp_coop_munge/tmp/lower_red_surface_DO_temp_2017.rds',
                      '7a_temp_coop_munge/tmp/lower_red_bottom2015.rds')
  start_date <- as.Date(time_range[1])
  stop_date <- as.Date(time_range[2])

  cd <- getwd()
  on.exit(setwd(cd))
  
  zippath <- file.path(getwd(), outfile)
  csv_file <- paste0(tools::file_path_sans_ext(basename(outfile)) ,'.csv')
  csv_path <- file.path(tempdir(), csv_file)
  
  feather::read_feather(temp_feather) %>% 
    filter(date >= start_date & date <= stop_date, site_id %in% site_ids, !source %in% remove_sources) %>% 
    select(-source) %>% 
    write_csv(path = csv_path)
  
  setwd(dirname(csv_path))
  zip(zipfile = zippath, files = csv_file)
  setwd(cd)
  
}
