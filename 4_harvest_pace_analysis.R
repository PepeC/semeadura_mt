###
#Analysis of harvest pace
###

library(nlme)
library(broom)
library(tidyverse)
library(minpack.lm)
library(lubridate)
library(AICcmodavg)

#Run get data R code.
source("1_get_data.R")

#wrangle colheita data
colheita_mt_w <- colheita_mt %>%
  #filter(!crop == "cotton") %>%
  pivot_longer(c(`CentroSul`:`Mato Grosso`), names_to = "macroregion", values_to = "val") %>%
  #create geounit names to match weather
  mutate(geounit = ifelse(macroregion == "MédioNorte" | macroregion == "Norte" | 
                          macroregion == "Noroeste", "BRA.MT.01",
                   ifelse(macroregion == "Nordeste", "BRA.MT.02",
                   ifelse(macroregion == "CentroSul", "BRA.MT.04",
                   ifelse(macroregion == "Sudeste", "BRA.MT.03",
                   ifelse(macroregion == "Oeste", "BRA.MT.05", NA)))))) %>%
  mutate(val = as.numeric(val), 
         val = val*100,
         date = as.Date(date),
         year = year(date),
         month = month(date),
         week = week(date), 
         doy = yday(date)) %>%
  group_by(crop, season, macroregion) %>%
  #Now, create a starting soy date. I took the floor of the earliest month in
  #the dataset, except for soy, where I used the start of the soy-free period in MT (9/16)
  mutate(min_year = min(year), 
         harv_start = ymd(paste(min_year, ifelse(crop == "cotton", "6",
                                                ifelse(crop == "corn", "05", "01")), 
                               "1", sep = "-"))) %>%
  ungroup() %>%
  mutate(doy_c = doy - yday(harv_start)) 

# Take a look at the data: Pace by end of October in MT
colheita_mt_w %>%
  filter(crop == "corn") %>%
  filter(month == 5 ) %>%
  filter(macroregion == "Mato Grosso") %>%
  group_by(year) %>%
  filter(doy == max(doy))

#Take a look at the data: Plot of sowing pace by district
colheita_mt_w %>%
  filter(crop == "soy") %>%
  filter(week < 20) %>%
  #filter(season == "12/13") %>%
  ggplot(aes(doy_c, val)) + 
  geom_line(aes(colour = season)) +
  xlab("Day fo Year") + 
  ylab("Harvest progress (%)") +
  facet_wrap(~macroregion) + 
  ggtitle("Soy harvest pace in Mato Grosso (2008/09 - 2019/20)")

# How do we model this? Logistic regression!
# We use the minpack.lm package to fit non-0linear regressions to a 
# form of the logistic function described in Pinheiro and Bates (in package nlme)
# The xmid parameter will be key so we can compare when 50% of sowings are complete.


#Test to get parameter starting value ideas
model_sem_col <- colheita_mt_w %>%
  filter(crop == "soy" & macroregion == "Nordeste" & year == 2016)

model_test_col <- gnls(val ~ SSlogis(doy_c, Asym, xmid, scal), model_sem_col)

#Now try
model_sem_col_nest <- colheita_mt_w %>%
  filter(!crop == "cotton") %>% #take out cotton for now
  group_by(crop, macroregion, geounit, season) %>%
  filter(!season == "20/21") %>% #filter out this season until data is complete
  nest() 

#Now run with do-catch
model_sem2_col <- colheita_mt_w %>%
  filter(!crop == "cotton") %>% #take out cotton for now
  filter(crop == "soy") %>% #try soy only
  group_by(crop, macroregion, season) %>%
  do( model = tryCatch(nlsLM(val ~ Asym/(1 + exp((xmid - doy_c)/scal)), 
                             start = list( Asym = 100, xmid = 70, scal = 13),
                             lower = c(Asym = 98, xmid = 30, scal = 8), 
                             upper = c(Asym = 101, xmid = 90, scal = 18), 
                             control = c(maxiter = 500),
                             na.action = na.exclude,
                             data = .)))  

model_sem3_col <- colheita_mt_w %>%
  filter(!crop == "cotton") %>% #take out cotton for now
  group_by(crop, macroregion, season) %>%
  do( model = tryCatch(nlsLM(val ~ Asym*exp(-exp(-scal*(doy_c-xmid))),
                             start = list( Asym = 100, xmid = 75, scal = 0.08),
                             lower = c(Asym = 98, xmid = 30, scal = 0.008), 
                             upper = c(Asym = 101, xmid = 90, scal = 1.8), 
                             control = c(maxiter = 500),
                             na.action = na.exclude,
                             data = .))) 


#Plot model results for last 
augment(model_sem3_col, model) %>%
  filter(crop == "soy") %>%
  #filter(season == "18/19" | season == "19/20" | season == "20/21") %>%
  #filter(season == "12/13") %>%
  ggplot(aes(doy_c, val)) +
  geom_point( shape = 1) + #aes(colour = season),
  geom_line(aes(doy_c, .fitted)) + #, colour = season
  xlab("Days after January 1st") + ylab("Harvest progress (%)") +
  theme_minimal() +
  facet_grid(season~macroregion) + 
  labs(
    title = "Soy harvest pace in Mato Grosso (2008/09-2019/20 Market Years)",
    subtitle = "",
    caption = "Data from IMEA (http://www.imea.com.br/imea-site/relatorios-mercado)"
  )

#Now, let's take a look at the parameters. Is there a relationship between
# the time 50% of soy sowings are complete and the time it takes after  
model_sem3_col %>%
  filter(!season=="20/21") %>% #remove this season from analyses
  tidy(model) %>%
  filter(term == "xmid") %>%
  select(crop:std.error) %>%
  pivot_wider(names_from = c(crop,term), values_from = c(estimate, std.error)) %>%
  ggplot(aes(estimate_soy_xmid,estimate_corn_xmid)) + 
  geom_point(size = 1.1) +
  geom_crossbar(aes(ymin = estimate_corn_xmid - 2*std.error_corn_xmid, 
                    ymax = estimate_corn_xmid + 2*std.error_corn_xmid, 
                    colour = season)) +
  geom_crossbar(aes(xmin = estimate_soy_xmid - 2*std.error_soy_xmid, 
                    xmax = estimate_soy_xmid + 2*std.error_soy_xmid, 
                    colour = season)) +
  xlab("Days to reach 50% soy sowings") + ylab("Days to reach 50% corn sowings") +
  facet_wrap(~macroregion) + 
  theme_bw() +
  labs(
    title = "Relationship between timing of the 50% sown mark is reached between soy and corn in Mato Grosso",
    subtitle = "Soybean is estimated at days since 16 September, while for corn it is days since 01 January",
    caption = "Data from IMEA (http://www.imea.com.br/imea-site/relatorios-mercado)"
  )

#Define this function to find the days after sowing related to any % completion
findInt <- function(model, value) {
  function(x) {
    predict(model, data.frame(doy_c = x), type="response") - value
  }
}

#Define days to test at 25% and 75 completion
prct_harv_25 <- 25
prct_harv_50 <- 50
prct_harv_75 <- 75

#now calculate for each crop x macroregion x year combo
model_sem3_col2 <- left_join(model_sem_col_nest, model_sem3_col) %>%
  group_by(crop, macroregion, season) %>%
  mutate(
    root_25 = map2(data, model, ~uniroot(findInt(.y, prct_harv_25), range(.x$doy_c))$root),
    root_50 = map2(data, model, ~uniroot(findInt(.y, prct_harv_50), range(.x$doy_c))$root),
    root_75 = map2(data, model, ~uniroot(findInt(.y, prct_harv_75), range(.x$doy_c))$root)
  )

#take a look
model_sem3_col2 %>%
  unnest(c(root_25, root_50, root_75)) 

model_sem_roots_col <- model_sem3_col2 %>% 
  unnest(c(root_25, root_50, root_75)) %>%
  select(crop, season, geounit, macroregion, root_25, root_50, root_75)

#create second data frame to plot points for key periods
model_sem_roots_col_plot <- model_sem_roots_col %>%
  gather(val, root, root_25:root_75) %>%
  separate(val, c("roots", "val"), sep ="_" , remove = TRUE, convert = TRUE) %>%
  select(-roots) %>%
  filter(crop == "soy") %>%
  filter(!macroregion == "Mato Grosso") %>%
  rename(doy_c = root) 

model_sem_roots_col_plot_line <- filter(model_sem_roots_col_plot, !val == 50) %>%
  spread(val, doy_c) %>%
  filter(!macroregion == "Mato Grosso") %>%
  mutate(dur50 = `75` -`25`)

#Plot model results for last 
augment(model_sem3_col, model) %>%
  filter(crop == "soy") %>%
  filter(!macroregion == "Mato Grosso") %>%
  ggplot(aes(doy_c, val)) +
  geom_point( shape = 1) + #aes(colour = season),
  geom_point(data = filter(model_sem_roots_col_plot, !val == 50), 
             aes(x = doy_c, y = val), colour = "red") +
  #geom_polygon(data = model_sem_roots_col_plot_all, aes(x = doy_c, y = val), 
  #             fill = "blue", alpha = 1/5)+
  geom_linerange(data = model_sem_roots_col_plot_line, 
                 aes(x = `25`, y = NULL, ymin = 0, ymax = 25), colour = "red") +
  geom_linerange(data = model_sem_roots_col_plot_line, 
                 aes(x = `75`, y = NULL, ymin = 0, ymax = 75), colour = "red") +
  geom_line(aes(doy_c, .fitted)) + #, colour = season
  xlab("Days after January 1st") + ylab("Harvest progress (%)") +
  xlim(0,110) + #take out a few unne
  theme_minimal() +
  facet_grid(season~macroregion) + 
  labs(
    title = "Soy harvest pace in Mato Grosso's macroregions (2008/09-2019/20 market years)",
    subtitle = "Red lines represent the points at which 25 and 75% of the crop is harvested",
    caption = "Data from IMEA (http://www.imea.com.br/imea-site/relatorios-mercado)"
  ) + 
  theme(plot.subtitle=element_text(size = 10, hjust = 0.001, face = "italic", color = "black"))


# Now do a quick regression just to get an idea. Best here is to do a regression 
# with errors in variables (e.g. Deming), and normalize/center vars

#First, wrangle daily weather variables  
#This first code creates summary rainfall and no. of days with rain for the last week fo december through Feb
bra_daily_mt2 <- bra_daily_mt %>%
  filter(vmnth == "Jan" | vmnth == "Dec" | vmnth == "Feb") %>%
  filter(vdoy > 354 | vdoy < 55) %>%
  mutate(vyear = ifelse(vmnth == "Dec", vyear + 1, vyear),
         raind = ifelse(prcp > 2, 1, 0)) %>% # create a rule for how many days it rains
  group_by(geounit, vyear) %>%
  summarise(.groups = "keep",
            sum_prcp = sum(prcp),
            sum_rday = sum(raind)) %>%
  rename(year = vyear)

#now create vars more relvant for the first 25%
bra_daily_mt3 <- bra_daily_mt %>%
  filter(vmnth == "Jan" | vmnth == "Dec") %>%
  filter(vdoy > 354 | vdoy < 55) %>%
  mutate(vyear = ifelse(vmnth == "Dec", vyear + 1, vyear),
         raind = ifelse(prcp > 2, 1, 0)) %>% # create a rule for how many days it rains
  group_by(geounit, vyear) %>%
  summarise(.groups = "keep",
            sum_prcp25 = sum(prcp),
            sum_rday25 = sum(raind)) %>%
  rename(year = vyear)


#Filter to take out the whole state as a test
model_sem_4b <-  model_sem_4 %>% 
  left_join(distinct(semeadura_mt_w, season, macroregion, geounit, year)) %>%
  filter(!macroregion == "Mato Grosso") %>%
  #filter(!season == "20/21") %>%
  filter(year  == max(year)) %>%
  left_join(bra_month_mt) %>%
  left_join(bra_daily_mt2) %>%
  left_join(bra_daily_mt3) %>%
  left_join(bra_soilm_mt) %>%
  group_by(macroregion, season, geounit) %>%
  mutate(prcp_decjan = (prcp_dec + prcp_jan), 
         prcp_jan2 = prcp_jan^2,
         nordeste = ifelse(macroregion == 'Nordeste', 'nordeste', 'other'))

# Look at some diagnostic plots
model_sem_4b %>%
  ggplot(aes(estimate_soy_xmid, estimate_corn_xmid)) + 
  geom_point(aes(colour = year)) + facet_wrap(~macroregion)

#simple linear model with additive soy pace var and macroregion fixed effects
model_lm_75 <- lm(estimate_corn_xmid ~ macroregion + estimate_soy_xmid, data = model_sem_4b)

#simple linear model with additive soy pace var, jan rains and macroregion fixed effects
model_lm_75_w <- lm(estimate_corn_xmid ~ macroregion + prcp_decjan + estimate_soy_xmid, data = model_sem_4b)

#simple linear model with additive soy pace var, jan rains and macroregion fixed effects
model_lm_75_w2 <- lm(estimate_corn_xmid ~ macroregion + prcp_jan + estimate_soy_xmid, data = model_sem_4b)

#simple linear model with additive soy pace var, jan rains and macroregion fixed effects
model_lm_75_w3 <- lm(estimate_corn_xmid ~ macroregion + tmax_jan*prcp_jan + estimate_soy_xmid, data = model_sem_4b)

#simple linear model with additive soy pace var, jan rains and macroregion fixed effects
model_lm_75_w4 <- lm(estimate_corn_xmid ~ macroregion + tmax_jan + prcp_jan + estimate_soy_xmid, data = model_sem_4b)

#simple linear model with additive soy pace var, jan rains and macroregion fixed effects
model_lm_75_w5 <- lm(estimate_corn_xmid ~ macroregion + prcp_feb + prcp_jan + estimate_soy_xmid, data = model_sem_4b)

#simple linear model with additive soy pace var, jan rains, year/trend and macroregion fixed effects
model_lm_75_w2b <- lm(estimate_corn_xmid ~ year + macroregion + prcp_jan + estimate_soy_xmid, data = model_sem_4b)

#simple linear model with additive soy pace var, jan rains, year/trend and macroregion fixed effects
model_lm_75_w2c <- lm(estimate_corn_xmid ~ sum_prcp + macroregion +  estimate_soy_xmid, data = model_sem_4b)

#simple linear model with additive soy pace var, jan rains, year/trend and macroregion fixed effects
model_lm_75_w2d <- lm(estimate_corn_xmid ~ macroregion + I(prcp_jan^2) + estimate_soy_xmid, data = model_sem_4b)

#simple linear model with additive soy pace var, jan rains and macroregion fixed effects
model_lm_75_w6 <- lm(estimate_corn_xmid ~ macroregion + soilm_jan + estimate_soy_xmid, data = model_sem_4b)

#simple linear model with additive soy pace var, jan rains and macroregion fixed effects
model_lm_75_w7 <- lm(estimate_corn_xmid ~ nordeste + prcp_jan + estimate_soy_xmid, data = model_sem_4b)

gas1 <- plsr(estimate_corn_xmid ~ estimate_soy_xmid, ncomp = 1, data = model_sem_4b, validation = "LOO")

gas2 <- plsr(estimate_corn_xmid ~ nordeste + prcp_jan + estimate_soy_xmid, ncomp = 3, data = model_sem_4b, validation = "LOO")

model_sem_4c <- 
  model_sem_4b %>% select(-soilm_dec)

gas3 <- plsr(estimate_corn_xmid ~ . , ncomp = 20, data = model_sem_4c, validation = "CV")

RMSEP(gas3)
gas2pred <- bind_cols(model_sem_4c, as.data.frame(predict(gas3,  newdata = model_sem_4c)))

plot(RMSEP(gas3), legendpos = "topright")

#take a look: Not terrible, but will certainly be improve by adding weather variables
#from December-Feb, especially rainfall and temperature (in that order).
#parameters here suggest that for each 10 day delay in reaching 50% sowing
tidy(model_lm_75_w2)
glance(model_lm_75_w2)

#Plot regression results with approx. 95% conf interval
augment(model_lm_75_w2, newdata = model_sem_4b) %>%
  ggplot(aes(estimate_soy_xmid, estimate_corn_xmid)) + 
  geom_point(aes(colour = season)) +
  geom_line(aes(estimate_soy_xmid, .fitted)) +
  geom_ribbon(aes(ymin = .fitted - 2*.se.fit, 
                  ymax = .fitted + 2*.se.fit), 
              linetype = 2, alpha = 0.5) +
  facet_wrap(~macroregion) + theme_bw()

#Plot regression results with approx. 95% conf interval
augment(model_lm_75_w7, newdata = model_sem_4c) %>%
  left_join(gas2pred) %>%
  distinct() %>%
  ggplot(aes(year, estimate_corn_xmid)) + 
  geom_point() +
  geom_line(aes(year, .fitted)) +
  geom_line(aes(year,  `estimate_corn_xmid.9 comps`), colour = 'green') +
  geom_line(aes(year,  `estimate_corn_xmid.17 comps`), colour = 'red') +
  # geom_line(aes(year,  `estimate_corn_xmid.3 comps`), colour = 'blue') +
  geom_ribbon(aes(ymin = .fitted - 2*.se.fit, 
                  ymax = .fitted + 2*.se.fit), 
              linetype = 2, alpha = 0.5) +
  facet_wrap(~macroregion) + theme_bw()


