% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/api.R
\name{annotation}
\alias{annotation}
\title{Extract user-specified annotations}
\usage{
annotation(x, type = NULL, ...)
}
\arguments{
\item{x}{the interacted object}

\item{type}{In a particular shiny view, the user might be looking at a
combination of samples or features. These both can be annotated, so the
caller needs to specify which subset of annotations they want. If left
\code{NULL} (default), the list of annotations will be returned}
}
\value{
a sample- or feature-level covariate table. If \code{type = NULL}, then
a list of all annotation tables is returnd
}
\description{
During the course of an analysis, users may annotate differente things
presented to them via the shiny interface. This function will pull out
the specficic feature type from the interacted object, should there be any.
}
