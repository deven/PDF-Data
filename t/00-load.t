#!/usr/bin/env perl

use v5.10;
use strict;
use warnings;

use Cwd            qw[abs_path];
use File::Basename qw[dirname];

use lib dirname(dirname(abs_path(__FILE__))) . "/lib";

use Test2::V0;

plan(1);

use ok 'PDF::Data';
