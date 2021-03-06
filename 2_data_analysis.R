library(nlme)
library(broom)
library(tidyverse)
library(minpack.lm)
library(lubridate)
library(AICcmodavg)
library(beepr)

#Run get data R code.
source("1_get_data.R")

#wrangle semeadura data
semeadura_mt_w <- semeadura_mt %>%
  filter(!crop == "cotton") %>%
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
         sow_start = ymd(paste(min_year, ifelse(crop == "cotton", "12",
                                         ifelse(crop == "corn", "01", "09")), 
                               ifelse(crop == "soy", "16", "1"), sep = "-"))) %>%
  ungroup() %>%
  mutate(doy_c = ifelse(year>min_year, doy + (365-yday(sow_start)), doy - yday(sow_start))) 

# Take a look at the data: Pace by end of October in MT
semeadura_mt_w %>%
  filter(crop == "soy") %>%
  filter(month == 10 ) %>%
  filter(macroregion == "Mato Grosso") %>%
  group_by(year) %>%
  filter(doy == max(doy))

#Take a look at the data: Plot of sowing pace by district
semeadura_mt_w %>%
  filter(crop == "soy") %>%
  filter(week > 10) %>%
  #filter(season == "12/13") %>%
  ggplot(aes(doy, val)) + 
  geom_line(aes(colour = season)) +
  xlab("Day fo Year") + 
  ylab("Sowing progress (%)") +
  facet_wrap(~macroregion) + 
  ggtitle("Soy sowing pace in Mato Grosso (2008/09 - 2019/20")

# How do we model this? Logistic regression!
# We use the minpack.lm package to fit non-0linear regressions to a 
# form of the logistic function described in Pinheiro and Bates (in package nlme)
# The xmid parameter will be key so we can compare when 50% of sowings are complete.


#Test to get parameter starting value ideas
model_sem <- semeadura_mt_w %>%
  filter(crop == "soy" & macroregion == "Nordeste" & year == 2016)

model_test <- gnls(val ~ SSlogis(doy_c, Asym, xmid, scal), model_sem)

#Now try
model_sem_nest <- semeadura_mt_w %>%
  group_by(crop, macroregion, geounit, season) %>%
  filter(!season == "20/21") %>% #filter out this season until data is complete
nest() 

#Now run with do-catch
model_sem2 <- semeadura_mt_w %>%
  group_by(crop, macroregion, season) %>%
  do( model = tryCatch(nlsLM(val ~ Asym/(1 + exp((xmid - doy_c)/scal)), 
                             start = list( Asym = 102, xmid = 53, scal = 8),
                             lower = c(Asym = 99, xmid = 2, scal = 2), 
                             upper = c(Asym = 101, xmid = 70, scal = 20), 
                             control = c(maxiter = 100),
                             na.action = na.exclude,
                             data = .)))  

#Plot model results for last 
augment(model_sem2, model) %>%
  filter(crop == "soy") %>%
  filter(season == "18/19" | season == "19/20" | season == "20/21") %>%
  #filter(season == "12/13") %>%
  ggplot(aes(doy_c, val)) +
  geom_point(aes(colour = season), shape = 1) + 
  geom_line(aes(doy_c, .fitted, colour = season)) + 
  xlab("Days after September 16th") + ylab("Sowing progress (%)") +
  theme_minimal() +
  facet_wrap(~macroregion) + 
  labs(
    title = "Soy sowing pace in Mato Grosso (2017/18-2020/21)",
    #subtitle = "Two seaters (sports cars) are an exception because of their light weight",
    caption = "Data from IMEA (http://www.imea.com.br/imea-site/relatorios-mercado)"
  )
  

#Now, let's take a look at the parameters. Is there a relationship between
# the time 50% of soy sowings are complete and the time it takes after  
model_sem2 %>%
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
prct_sowing_25 <- 25
prct_sowing_75 <- 75

#now calculate for each crop x macroregion x year combo
model_sem3 <- left_join(model_sem_nest, model_sem2) %>%
  group_by(crop, macroregion, season) %>%
  mutate(
    root_25 = map2(data, model, ~uniroot(findInt(.y, prct_sowing_25), range(.x$doy_c))$root),
    root_75 = map2(data, model, ~uniroot(findInt(.y, prct_sowing_75), range(.x$doy_c))$root)
  )

#take a look
model_sem3 %>%
unnest(c(root_25, root_75)) 

model_sem_roots <- model_sem3 %>% 
  unnest(c(root_25, root_75)) %>%
  select(crop, season, geounit, macroregion, root_25, root_75)

#Now try plot again, but this time with the 75% completion for each one
model_sem_4 <- model_sem2 %>%
  tidy(model) %>%
  filter(term == "xmid") %>%
  select(crop:std.error) %>% 
  left_join(model_sem_roots) %>%
  pivot_wider(names_from = c(crop,term), 
              values_from = c(estimate, std.error, root_25, root_75)) 
  
#now plot
  model_sem_4 %>%
  ggplot(aes(root_75_soy_xmid, estimate_corn_xmid)) + geom_point(aes(colour = season)) +
  facet_wrap(~macroregion) + theme_bw()

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

#try with lasso
model_lm_75_lass0 <- glmnet(estimate_corn_xmid ~ macroregion + soilm_jan + estimate_soy_xmid, data = model_sem_4b)

varr2 <- model_sem_4b %>%
  select(-contains("corn_xmid"), -prev_year, -tmin_dec, -contains("std.error"), 
         -ptavg_feb, -ptmin_jan) %>%
  colnames()

aa2 <- as.formula( paste("estimate_corn_xmid~ ", "(", paste( varr2, collapse = " + " ), ")^2"))

set.seed(131313)

m_yield <- train(aa2,
           data = model_sem_4b,
           method = "pls",
           tuneLength = 40,
           na.action = na.omit,
           returnData = TRUE,
           preProcess = c('knnImpute', 'zv', 'nzv', 'center', 'scale'),
           trControl = trainControl(method = "repeatedcv", number = 5, repeats = 5)) 

summary(m_yield)

m_yield2 <- train(aa2,
            data = model_sem_4b,
            method = "lasso",
            tuneLength = 40,
            na.action = na.omit,
            preProcess = c('knnImpute', 'zv', 'nzv', 'center', 'scale'),
            trControl = trainControl(method = "repeatedcv", number = 5, repeats = 5))

plot(m_yield$results[,1:2])
varImp(m_yield)


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
