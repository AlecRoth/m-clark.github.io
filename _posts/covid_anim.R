
# Country Level Counts from WHO Incidence ---------------------------------


library(rvest)
library(tidyverse)


# Unfortunately, JH repo doesn't keep up the situation reports so we snag them
# from Wikipedia.  But the Wiki changes, and has numerous issues, so what works
# one day probably won't another.

site = 'https://en.wikipedia.org/wiki/Template:2019%E2%80%9320_coronavirus_outbreak_data/WHO_situation_reports'

init = read_html(site) %>% 
  html_table(fill = T)

length(init)

map(init, dim)


# map(init, glimpse)

# depending on the time you get it, do it the starting table could be any of the
# initial ones, and still is very poorly organized besides
data_of_interest = which(
  map_lgl(init, function(x)
    any(str_detect(colnames(x ), 'Date'))
  )
)

# need to remove stupid bracket footnotes
clean_tables <- function(data, world = FALSE, doubling = FALSE) {
  # it is a so-called 'feature' that na columns can't be dealt with; and as long
  # as they exist, nothing in tidyverse will work.
  data = as_tibble(data, .name_repair = 'unique')
  data = select(data, -starts_with('...'))
  
  world_data = filter(data, str_detect(Date, 'World|Doubling|Total'))
  data = filter(data, !str_detect(Date, 'Date|World|Doubling|Total|Notes|References'))
  
  na_columns = which(map_lgl(data, function(x) all(is.na(x)))) 
  
  data[, na_columns] = NULL
  world_data[, na_columns] = NULL

  colnames(data)[1] = colnames(world_data)[1] = 'region'  # currently incorrectly called 'Date'
  
  if (world) {
    data = world_data %>% 
      mutate(region = if_else(duplicated(region), 'Doubling (except China)', region))
    
    if (!doubling)
      data = world_data %>% 
        filter(!str_detect(region, 'Doubling')) 

  } 
  
  data = data %>% 
    rename(first_report = `First reported case`) %>% 
    # remove footnotes and commas
    mutate_at(vars(-region, -first_report), function(x)
      str_remove_all(x, '\\[(.*?)\\]')) %>% 
    mutate_at(vars(-region, -first_report), function(x)
      as.numeric(str_remove_all(x, '[[:punct:]]'))) %>%
    # reshape
    pivot_longer(c(-region,-first_report),
                 names_to = 'date',
                 values_to = 'count') %>% 
    # deal with dates
    mutate(first_report = lubridate::mdy(first_report)) %>%   # they will probably change format at some point
    separate(date, into = c('month', 'day')) %>% 
    mutate(date = lubridate::ymd(glue::glue('2020-{month}-{day}'))) 
  
  if (world) 
    return(select(data, -first_report))
  else
    data
}

# check it hear
# debugonce(clean_tables)
clean_tables(init[[data_of_interest[1]]], world = F)
clean_tables(init[[data_of_interest[3]]], world = T)

# check start and end tables!
countries = map_df(init[data_of_interest], clean_tables)  
world = map_df(init[data_of_interest], clean_tables, world = TRUE, doubling = TRUE)

all = bind_rows(countries, world) %>% 
  filter(!grepl(region, pattern = 'Total|except'))

library(gganimate)

highlight = c('USA',
              'China',
              'Japan',
              'South Korea',
              'Italy',
              'Iran',
              'UK',
              'France',
              'Germany',
              'Spain')

p = all %>% 
  ggplot(aes(x = date, y = count)) +
  geom_path(aes(group = region), alpha = .01) +
  geom_point(
    aes(),
    size = 6,
    alpha = .1,
    data = filter(world, region == 'World')
  ) +
  geom_point(
    aes(color = region),
    size = 1.5,
    alpha = .5,
    data = filter(countries, region %in% highlight)
  ) +
  scico::scale_color_scico_d(begin = .1, end = .9) +
  scale_x_date(date_breaks = '2 weeks') +
  scale_y_continuous(trans = 'log',
                     breaks = c(50, 100, 500, 1000, 5000, 10000, 50000, 100000),
                     labels = scales::comma) +
  visibly::theme_clean() + 
  labs(x = '', caption = 'Dark large dot is world total') +
  theme(
    axis.text.x  = element_text(size = 6),
    axis.ticks.y = element_blank(),
    legend.title       = element_blank(),
    legend.key.size    = unit(.25, 'cm'),
    legend.text        = element_text(size = 6),
    legend.box.spacing = unit(0, 'mm'),
    legend.box.margin  = margin(0),
    title = element_text(size = 12)
  )

p

ggsave('img/covid.svg')

p_anim = p +
  transition_reveal(date) +
  shadow_wake(wake_length = 1/3, falloff = "cubic-in-out") 

p_animate = animate(
  p_anim,
  nframes = 120,
  fps = 10,
  start_pause = 10,
  end_pause = 10,
  width = 800,
  height = 600,
  res = 144
)
  
p_animate %>% print(dpi = 1000)

anim_save('img/covid.gif')



# Model it ----------------------------------------------------------------


# plot doubling

world %>% filter(str_detect(region, 'Doubling')) %>% qplot(
  data = .,
  x = date,
  y = count,
  geom = 'path',
  color = region
)

# plot derivs
all_for_model = all %>% 
  mutate(region = factor(region),
         date_num = as.numeric(date)) %>% 
  group_by(region) %>% 
  mutate(N = n()) %>% 
  ungroup() %>% 
  filter(
    (region %in% highlight | 
       N >= 40 & 
       !region %in% c('World', 'Doubling (days)', 'International conveyance')
    ) & 
      date >= '2020-02-01'
  ) %>% 
  droplevels()


library(lubridate)

library(mgcv)

mod = bam(
  count ~ s(date_num, region, bs = 'fs', k = 5),
  # family = ziP(),
  # family = Gamma(link = 'log'),
  family = gaussian(link = 'log'),
  data = all_for_model,
  nthreads = 10
)

summary(mod)

visibly::plot_gam_by(
  mod,
  date_num,
  region,
  begin = .1,
  end = .8,
  alpha = .7
  ) +
  geom_text(
    aes(label = region),
    size = 2,
    vjust = -.75,
    show.legend = FALSE,
    data = . %>% filter(date_num == max(date_num) & region %in% highlight)
  )

plotly::ggplotly()

library(gratia)

deriv_dat_1 = derivatives(mod, term = 'date_num', n = 250)

plot_dat = deriv_dat_1 %>% 
  mutate(
    date = lubridate::as_date(data),
    region = str_remove_all(smooth, 's\\(date_num\\):region'),
    region = fs_var
  )


plot_dat_peaks_valleys = plot_dat %>%
  group_by(region) %>% 
  slice(quantmod::findPeaks(derivative)-1, 
        quantmod::findValleys(derivative)-1)  # see helpfile for why -1


library(ggrepel)

plot_dat %>% 
  ggplot(aes(date, y = derivative)) +
  # geom_ribbon(aes(ymin=lower, ymax=upper, group=region), alpha = .02) +
  geom_hline(yintercept = 0, color = 'gray92') +
  geom_line(aes(color = region), alpha = .5) +
  geom_point(aes(color = region), size = 2, data = plot_dat_peaks_valleys %>% filter(region == 'China')) +
  geom_text_repel(
    aes(label = as.character(date), color = region), 
    size = 2,
    alpha = .5,
    data = plot_dat_peaks_valleys %>% filter(region == 'China')) +
  geom_text_repel(
    aes(label = region), 
    size = 2,
    alpha = .5,
    data = plot_dat %>% filter(date == max(date) & derivative > 50)) +
  labs(x = '') +
  scico::scale_color_scico_d(begin = .25, end = .75) +
  visibly::theme_clean() +
  theme(
    legend.position = 'bottom',
  )



# Johns Hopkins ----------------------------------------------------------------

# Get data from JH repo
library(tidyverse)

import_and_clean_data = function(
  current = FALSE,
  us_only = FALSE,
  state_city = 'state'
  ) {
  
  confirmed_url = 'https://github.com/CSSEGISandData/COVID-19/raw/master/csse_covid_19_data/csse_covid_19_time_series/time_series_19-covid-Confirmed.csv'
  deaths_url    = 'https://github.com/CSSEGISandData/COVID-19/raw/master/csse_covid_19_data/csse_covid_19_time_series/time_series_19-covid-Deaths.csv'
  recovered_url = 'https://github.com/CSSEGISandData/COVID-19/raw/master/csse_covid_19_data/csse_covid_19_time_series/time_series_19-covid-Recovered.csv'
  
  confirmed = read_csv(confirmed_url)
  deaths = read_csv(deaths_url)
  recovered = read_csv(recovered_url)
  
  df_list = list(confirmed = confirmed,
                 deaths = deaths,
                 recovered = recovered)

  data  = df_list %>% 
    map_df(
      function(x)
        x %>% 
        rename(province_state = `Province/State`,
               country_region = `Country/Region`) %>% 
        pivot_longer(
          c(-province_state,-country_region,-Lat,-Long),
          names_to = 'date',
          values_to = 'count'
        ) %>% 
        mutate(date = lubridate::mdy(date)),
      .id = 'type'
    )
  
  
  if (current)
    data = data %>% 
    group_by(country_region, province_state, type) %>% 
    slice(n())
  
  if (us_only) {
    # this will remove city rows, which mostly just have zero count anyway
    if (state_city == 'state') {
      data = data %>% 
        filter(country_region == 'US', province_state %in% state.name) %>% 
        rename(state = province_state) %>% 
        select(-country_region)     
    } 
    else {
      data = data %>% 
        filter(country_region == 'US', !province_state %in% state.name) %>% 
        rename(state = province_state) %>% 
        select(-country_region)     
    }
  }
  
  data
} 



# debugonce(import_and_clean_data)
world = import_and_clean_data()
world_current = import_and_clean_data(current = TRUE)
us_current = import_and_clean_data(us_only = TRUE, current = TRUE)
us_series = import_and_clean_data(us_only = TRUE, current = FALSE)

world_death_rates = world_current %>% 
  filter(type == 'confirmed' | type == 'deaths') %>% 
  pivot_wider(names_from = type, values_from = count) %>% 
  group_by(country_region) %>% 
  summarise(
    confirmed = sum(confirmed),
    deaths = sum(deaths),
    rate = deaths/confirmed
    ) %>% 
  arrange(desc(rate))

us_death_rates = us_current %>% 
  filter(type == 'confirmed' | type == 'deaths') %>% 
  pivot_wider(names_from = type, values_from = count) %>% 
  mutate(rate = deaths/confirmed) %>% 
  arrange(desc(rate))

world_death_rates %>%
  summarise(
    rate = sum(deaths) / sum(confirmed),
    rate_no_italy = 
      sum(deaths[country_region != 'Italy']) / 
      sum(confirmed[country_region != 'Italy'])
  )


us_death_rates %>% 
  summarise(rate = sum(deaths)/sum(confirmed))

# install.packages("statebins", repos = "https://cinc.rud.is")

library(statebins)

us_current %>% 
  filter(type == 'confirmed') %>% 
  statebins(
    value_col = "log(count)",
    palette = "OrRd", 
    direction = 1,
    name = "Covid Counts (log)"
  ) +
  statebins::theme_statebins()

us_death_rates %>% 
  statebins(
    value_col = "rate",
    palette = "OrRd", 
    direction = 1,
    name = "Death Rate"
  ) +
  statebins::theme_statebins()

library(geofacet)

us_series %>% 
  filter(count != 0, type == 'confirmed') %>% 
  ggplot(aes(date, count, group = state)) +
  geom_path(color = '#ff550080') +
  labs(y = '', x = '') +
  visibly::theme_clean() +
  facet_geo(~state, scales = 'free') +
  theme(
    axis.text.x = element_blank(),
    axis.ticks.x = element_blank(),
    axis.text.y = element_text(size = 4),
    strip.text = element_text(size = 4),
  )




# nytimes dot -------------------------------------------------------------

world_confirmed = world %>% 
  filter(type == 'confirmed', country_region != 'Cruise Ship')

world_current = world_confirmed %>% 
  group_by(country_region, province_state) %>% 
  filter(date == max(date)) %>% 
  group_by(country_region) %>% 
  mutate(total_current = sum(count)) %>% 
  distinct(country_region, date, total_current) %>% 
  ungroup()

top_20 = world_current %>% 
  top_n(20, total_current) %>% 
  arrange(desc(total_current))
 
plot_data = world_confirmed %>%
  group_by(country_region, date) %>%
  mutate(country_cases = sum(count)) %>%
  distinct(country_region, date, country_cases) %>%
  group_by(country_region) %>%
  mutate(new_cases = country_cases - lag(country_cases),
         total_cases = sum(country_cases)) %>%
  ungroup() %>%
  filter(country_region %in% top_20$country_region) %>%
  mutate(
    country_region = ordered(country_region, levels = rev(top_20$country_region)),
    line_positions = as.numeric(country_region) + .5,
    line_positions = ifelse(line_positions == max(line_positions), NA, line_positions)
  ) 
  
plot_data %>% 
  ggplot(aes(x = date, y = country_region)) +
  geom_tile(aes(
    fill = new_cases,
    width = .9,
    height = 0.5
  ),
  na.rm = T,
  size = 2) +
  geom_hline(aes(yintercept = line_positions),
             color = 'gray92',
             size = .25) +
  scico::scale_fill_scico(
    end = .75,
    na.value = 'gray98',
    palette = 'lajolla',
    trans = 'log',
    breaks = c(5, 25, 100, 500, 2500)
  ) +
  labs(x = '', y = '') +
  guides(fill = guide_legend(title = 'New Cases')) +
  visibly::theme_clean() +
  theme(
    axis.ticks.y = element_blank(),
    legend.text = element_text(size = 6),
    legend.title = element_text(size = 10)
  )


# JH Repo WHO Situation ---------------------------------------------------

# as mentioned above, while this data is cleaner, it isn't being updated, and at
# present about three weeks old, but should they update them, they are likely more
# usable and less volatile than the wikipedia data

who_situation = read_csv('https://github.com/CSSEGISandData/COVID-19/raw/master/who_covid_19_situation_reports/who_covid_19_sit_rep_time_series/who_covid_19_sit_rep_time_series.csv')

glimpse(who_situation)

who_situation = who_situation %>% 
  select(-starts_with('X')) %>%   # these are empty columns
  rename(province_state = `Province/States`,
         country_region = `Country/Region`,
         who_region = `WHO region`) %>% 
  pivot_longer(
    c(-province_state, -country_region, -who_region),
    names_to = 'date',
    values_to = 'count'
  ) %>% 
  mutate(date = lubridate::mdy(date))
